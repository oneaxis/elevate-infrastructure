import type { Request, Response } from 'express';
import { initializeApp } from 'firebase-admin/app';
import { getAppCheck } from 'firebase-admin/app-check';

// Application Default Credentials are picked up from the Cloud Run metadata
// server; no service account keys are ever baked into the deployment.
initializeApp();

// Every supported upstream (Z.ai/GLM, Groq, Google Gemini, OpenRouter, ...)
// exposes an OpenAI-compatible /chat/completions endpoint, so a single client
// serves them all. The failover chains below are plain ordered lists of
// "provider:model" entries — adding a provider means adding
// {PROVIDER}_BASE_URL + a {PROVIDER}_API_KEY secret, never code changes.
const CHAIN_MAIN = envOrDefault(
  'AI_CHAIN_MAIN',
  'glm:glm-5.3-flash,groq:openai/gpt-oss-120b,groq:openai/gpt-oss-20b,' +
    'openrouter:nvidia/nemotron-3-super-120b-a12b:free,' +
    'gemini:gemini-3.7-flash,gemini_paid:gemini-3.7-flash',
);
const CHAIN_SECONDARY = envOrDefault(
  'AI_CHAIN_SECONDARY',
  'groq:openai/gpt-oss-20b,groq:openai/gpt-oss-120b,' +
    'openrouter:nvidia/nemotron-3-super-120b-a12b:free,' +
    'gemini:gemini-3.5-flash-lite,gemini_paid:gemini-3.5-flash-lite',
);

// Latency policy: the client should get a reply in human time. Each attempt
// gets at most UPSTREAM_TIMEOUT_MS; the whole chain walk stops at
// TOTAL_BUDGET_MS (kept below the 30s function timeout so we can still return
// a clean 502 instead of a client-side timeout).
const UPSTREAM_TIMEOUT_MS = numOrDefault('UPSTREAM_TIMEOUT_MS', 8_000);
const TOTAL_BUDGET_MS = numOrDefault('TOTAL_BUDGET_MS', 25_000);
const MAX_MESSAGES = 20;
const MAX_CONTENT_CHARS = 8_000;
/** Best-effort burst protection for the free GLM/Groq quotas (3 req/min). */
const BURST_LIMIT_PER_MINUTE = 3;

/** Upstream statuses that trigger failover: concurrency/limits (429), GLM
 *  balance exhaustion (402), retired/missing models (404), request timeouts (408)
 *  and upstream outages (5xx). 401/403/400 are configuration bugs and fail loudly instead. */
const FAILOVER_STATUSES = new Set([402, 404, 408, 429, 500, 502, 503, 504]);

type ModelTier = 'main' | 'secondary';

interface ChainEntry {
  provider: string;
  model: string;
}

interface GatewayRequest {
  modelTier?: ModelTier;
  messages?: Array<{ role: string; content: string }>;
  prompt?: string;
}

interface GatewayResponse {
  reply: string;
  modelUsed: string;
  provider: string;
}

interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

class UpstreamError extends Error {
  constructor(
    public readonly provider: string,
    public readonly status: number,
    public readonly body: string,
  ) {
    super(`${provider} responded with HTTP ${status}`);
  }
}

function envOrDefault(name: string, fallback: string): string {
  const value = process.env[name];
  return value && value.trim().length > 0 ? value : fallback;
}

function numOrDefault(name: string, fallback: number): number {
  const parsed = Number(process.env[name]);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function parseChain(csv: string): ChainEntry[] {
  return csv
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const separator = entry.indexOf(':');
      return separator <= 0
        ? null
        : {
            provider: entry.slice(0, separator),
            model: entry.slice(separator + 1),
          };
    })
    .filter((entry): entry is ChainEntry => entry !== null);
}

const burstWindow = new Map<string, number[]>();

function isBurstLimited(appCheckToken: string): boolean {
  const now = Date.now();
  const windowStart = now - 60_000;
  const hits = (burstWindow.get(appCheckToken) ?? []).filter((t) => t > windowStart);
  if (hits.length >= BURST_LIMIT_PER_MINUTE) {
    burstWindow.set(appCheckToken, hits);
    return true;
  }
  hits.push(now);
  burstWindow.set(appCheckToken, hits);
  return false;
}

async function chatCompletion(
  provider: string,
  baseUrl: string,
  apiKey: string,
  model: string,
  messages: ChatMessage[],
  timeoutMs: number,
): Promise<string> {
  const response = await fetch(`${baseUrl}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({ model, messages }),
    // Fail fast: retries are handled by walking the chain, not by fetch.
    signal: AbortSignal.timeout(timeoutMs),
  });

  if (!response.ok) {
    throw new UpstreamError(provider, response.status, await response.text());
  }

  const payload = (await response.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const reply = payload.choices?.[0]?.message?.content;
  if (!reply) {
    throw new UpstreamError(provider, 502, 'Upstream returned no completion content');
  }
  return reply;
}

function normalizeMessages(body: GatewayRequest): ChatMessage[] | null {
  const raw =
    body.messages ??
    (body.prompt ? [{ role: 'user', content: body.prompt }] : null);
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_MESSAGES) {
    return null;
  }
  const messages: ChatMessage[] = [];
  for (const message of raw) {
    if (typeof message?.content !== 'string' || message.content.length === 0) {
      return null;
    }
    if (message.content.length > MAX_CONTENT_CHARS) {
      return null;
    }
    const role =
      message.role === 'system' || message.role === 'assistant'
        ? message.role
        : 'user';
    messages.push({ role, content: message.content });
  }
  return messages;
}

export async function aiGateway(req: Request, res: Response): Promise<void> {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type, X-Firebase-AppCheck');
  if (req.method === 'OPTIONS') {
    res.set('Access-Control-Allow-Methods', 'POST');
    res.status(204).end();
    return;
  }
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Only POST requests are supported.' });
    return;
  }

  // App Check enforcement: hardware attestation (Play Integrity / App Attest),
  // consumed to defeat replay attacks. Equivalent to
  // enforceAppCheck + consumeAppCheckToken in the Firebase SDK.
  const appCheckToken = req.get('X-Firebase-AppCheck');
  if (!appCheckToken) {
    res.status(401).json({ error: 'Missing App Check token.' });
    return;
  }
  try {
    await getAppCheck().verifyToken(appCheckToken, { consume: true });
  } catch (error) {
    console.warn('App Check verification failed', error);
    res.status(403).json({ error: 'Invalid App Check token.' });
    return;
  }

  if (isBurstLimited(appCheckToken)) {
    res.status(429).json({ error: 'Rate limit exceeded. Retry in a minute.' });
    return;
  }

  const body = (req.body ?? {}) as GatewayRequest;
  const tier: ModelTier = body.modelTier === 'secondary' ? 'secondary' : 'main';
  const messages = normalizeMessages(body);
  if (!messages) {
    res.status(400).json({
      error: `Provide "prompt" or "messages" (1-${MAX_MESSAGES} entries, max ${MAX_CONTENT_CHARS} chars each).`,
    });
    return;
  }

  try {
    const result = await route(tier, messages);
    res.status(200).json(result satisfies GatewayResponse);
  } catch (error) {
    console.error('Gateway failed', error);
    res.status(502).json({ error: 'All upstream providers failed.' });
  }
}

async function route(
  tier: ModelTier,
  messages: ChatMessage[],
): Promise<GatewayResponse> {
  const chain = parseChain(tier === 'main' ? CHAIN_MAIN : CHAIN_SECONDARY);
  const deadline = Date.now() + TOTAL_BUDGET_MS;
  let lastError: unknown = new Error('Provider chain is empty');

  for (const attempt of chain) {
    const remaining = deadline - Date.now();
    // Keep a slice of budget so we can still answer after the walk fails.
    const timeoutMs = Math.min(UPSTREAM_TIMEOUT_MS, remaining - 1_000);
    if (timeoutMs <= 0) {
      console.warn(`Latency budget exhausted before ${attempt.provider}:${attempt.model}`);
      break;
    }

    const baseUrl = process.env[`${attempt.provider.toUpperCase()}_BASE_URL`];
    const apiKey = process.env[`${attempt.provider.toUpperCase()}_API_KEY`];
    if (!baseUrl || !apiKey) {
      console.warn(`Provider ${attempt.provider} is not configured, skipping`);
      continue;
    }

    try {
      const reply = await chatCompletion(
        attempt.provider,
        baseUrl,
        apiKey,
        attempt.model,
        messages,
        timeoutMs,
      );
      return { reply, modelUsed: attempt.model, provider: attempt.provider };
    } catch (error) {
      const isUpstreamError = error instanceof UpstreamError;
      const shouldFailover =
        !isUpstreamError || FAILOVER_STATUSES.has(error.status);
      if (!shouldFailover) {
        throw error;
      }
      console.warn(
        `${attempt.provider}:${attempt.model} failed (${
          isUpstreamError ? `HTTP ${error.status}` : 'network/timeout'
        }), moving to the next provider`,
      );
      lastError = error;
    }
  }
  throw lastError;
}

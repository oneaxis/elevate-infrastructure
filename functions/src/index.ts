import type { Request, Response } from 'express';
import { initializeApp } from 'firebase-admin/app';
import { getAppCheck } from 'firebase-admin/app-check';

// Application Default Credentials are picked up from the Cloud Run metadata
// server; no service account keys are ever baked into the deployment.
initializeApp();

const GLM_BASE_URL = process.env.GLM_BASE_URL ?? 'https://api.z.ai/api/paas/v4';
const GROQ_BASE_URL = process.env.GROQ_BASE_URL ?? 'https://api.groq.com/openai/v1';
// Free-capable lineup as of 2026-09 (see README "Model selection & rate limits"):
// glm-5.3-flash currently free with 50 concurrent requests; glm-4-flash was retired.
const GLM_MODEL = process.env.GLM_MODEL ?? 'glm-5.3-flash';
// Groq free tier (30 RPM / 1K RPD each): official llama-3.x replacements.
const GROQ_FAILOVER_MODELS = (
  process.env.GROQ_FAILOVER_MODELS ?? 'openai/gpt-oss-120b,openai/gpt-oss-20b'
)
  .split(',')
  .map((m) => m.trim())
  .filter(Boolean);
const GROQ_SECONDARY_MODEL = process.env.GROQ_SECONDARY_MODEL ?? 'openai/gpt-oss-20b';

/** Upstream statuses that trigger failover: concurrency/limits (429), GLM
 *  outages (503/504) and balance exhaustion (402, e.g. if GLM drops free tier). */
const FAILOVER_STATUSES = new Set([429, 402, 503, 504]);
const UPSTREAM_TIMEOUT_MS = 12_000;
const MAX_MESSAGES = 20;
const MAX_CONTENT_CHARS = 8_000;
/** Best-effort burst protection for the free GLM concurrency quota (3 req/min). */
const BURST_LIMIT_PER_MINUTE = 3;

type ModelTier = 'main' | 'secondary';
type GatewayProvider = 'glm' | 'groq-backup' | 'groq-secondary';

interface GatewayRequest {
  modelTier?: ModelTier;
  messages?: Array<{ role: string; content: string }>;
  prompt?: string;
}

interface GatewayResponse {
  reply: string;
  modelUsed: string;
  provider: GatewayProvider;
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
  baseUrl: string,
  apiKey: string,
  model: string,
  messages: ChatMessage[],
): Promise<string> {
  const response = await fetch(`${baseUrl}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({ model, messages }),
    // Fail fast: retries are handled by the failover logic, not by fetch.
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });

  if (!response.ok) {
    throw new UpstreamError(baseUrl, response.status, await response.text());
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
  const groqKey = process.env.GROQ_API_KEY ?? '';
  const glmKey = process.env.GLM_API_KEY ?? '';

  // Each tier tries its primary provider first, then walks the failover chain
  // on rate-limit / outage / balance errors.
  const chain: Array<{
    baseUrl: string;
    apiKey: string;
    model: string;
    provider: GatewayProvider;
  }> =
    tier === 'main'
      ? [
          {
            baseUrl: GLM_BASE_URL,
            apiKey: glmKey,
            model: GLM_MODEL,
            provider: 'glm',
          },
          ...GROQ_FAILOVER_MODELS.map((model) => ({
            baseUrl: GROQ_BASE_URL,
            apiKey: groqKey,
            model,
            provider: 'groq-backup' as const,
          })),
        ]
      : [
          {
            baseUrl: GROQ_BASE_URL,
            apiKey: groqKey,
            model: GROQ_SECONDARY_MODEL,
            provider: 'groq-secondary',
          },
          {
            baseUrl: GLM_BASE_URL,
            apiKey: glmKey,
            model: GLM_MODEL,
            provider: 'glm',
          },
        ];

  let lastError: unknown;
  for (const attempt of chain) {
    try {
      const reply = await chatCompletion(
        attempt.baseUrl,
        attempt.apiKey,
        attempt.model,
        messages,
      );
      return { reply, modelUsed: attempt.model, provider: attempt.provider };
    } catch (error) {
      const shouldFailover =
        error instanceof UpstreamError && FAILOVER_STATUSES.has(error.status);
      if (!shouldFailover) {
        throw error;
      }
      console.warn(
        `${attempt.model} responded with ${(error as UpstreamError).status}, failing over`,
      );
      lastError = error;
    }
  }
  throw lastError;
}

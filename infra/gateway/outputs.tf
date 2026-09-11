output "gateway_url" {
  description = "Public HTTPS endpoint of this gateway environment."
  value       = google_cloudfunctions2_function.gateway.service_config[0].uri
}

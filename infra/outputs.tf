output "website_url" {
  description = "Public URL of the static website."
  value       = azurerm_storage_account.site.primary_web_endpoint
}

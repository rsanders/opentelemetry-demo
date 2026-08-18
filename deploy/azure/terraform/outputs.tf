output "public_ip" {
  description = "Static public IP of the demo VM."
  value       = azurerm_public_ip.this.ip_address
}

output "app_url" {
  description = "URL of the demo frontend."
  value       = "http://${azurerm_public_ip.this.ip_address}"
}

output "ssh_command" {
  description = "SSH command for the demo VM."
  value       = "ssh -i ${local_sensitive_file.ssh_private_key.filename} azureuser@${azurerm_public_ip.this.ip_address}"
}

output "ansible_inventory_path" {
  description = "Terraform-generated Ansible inventory path."
  value       = local_file.ansible_inventory.filename
}

output "application_insights_resource_id" {
  description = "Resource ID for Application Insights telemetry."
  value       = azurerm_application_insights.this.id
}

output "log_analytics_workspace_id" {
  description = "Resource ID for the Log Analytics workspace storing telemetry."
  value       = azurerm_log_analytics_workspace.this.id
}

output "azure_monitor_workspace_id" {
  description = "Resource ID for the Azure Monitor Workspace storing native OTLP metrics."
  value       = azurerm_monitor_workspace.this.id
}

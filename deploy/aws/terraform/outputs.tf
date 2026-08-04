output "public_ip" {
  description = "Public IP of the demo instance."
  value       = aws_instance.this.public_ip
}

output "app_url" {
  description = "URL of the demo frontend (frontend-proxy / ENVOY_PORT)."
  value       = "http://${aws_instance.this.public_ip}:8080"
}

output "ssh_command" {
  description = "Command to SSH into the instance."
  value       = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ec2-user@${aws_instance.this.public_ip}"
}

output "ssm_command" {
  description = "Command to open a Session Manager shell on the instance (no SSH key or open port needed; requires the Session Manager plugin for the AWS CLI)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.this.id}"
}

output "ansible_inventory_path" {
  description = "Path to the Ansible inventory generated for this instance."
  value       = local_file.ansible_inventory.filename
}

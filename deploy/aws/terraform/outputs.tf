output "public_ip" {
  description = "Static public (Elastic) IP of the demo instance. Stable across instance replacement."
  value       = aws_eip.this.public_ip
}

output "app_url" {
  description = "URL of the demo frontend (frontend-proxy), on the standard HTTP port."
  value       = "http://${aws_eip.this.public_ip}"
}

output "ssh_command" {
  description = "Command to SSH into the instance."
  value       = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ec2-user@${aws_eip.this.public_ip}"
}

output "ssm_command" {
  description = "Command to open a Session Manager shell on the instance (no SSH key or open port needed; requires the Session Manager plugin for the AWS CLI)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.this.id}"
}

output "ansible_inventory_path" {
  description = "Path to the Ansible inventory generated for this instance."
  value       = local_file.ansible_inventory.filename
}

output "alerts_topic_arn" {
  description = "SNS topic CloudWatch alarms notify on instance/service downtime, if alert_email is set. Check the subscribed email for a confirmation link -- alerts don't arrive until it's clicked."
  value       = try(aws_sns_topic.alerts[0].arn, null)
}

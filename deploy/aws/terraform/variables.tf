variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used to tag/name all resources (also used as the CloudWatch namespace prefix)."
  type        = string
  default     = "otel-demo"
}

variable "instance_type" {
  description = "EC2 instance type running the full docker compose stack. t3.xlarge (4 vCPU/16GB) gives headroom over the ~3.2GB of container memory limits declared by compose.yaml alone."
  type        = string
  default     = "t3.xlarge"
}

variable "root_volume_size_gb" {
  description = "Size in GB of the instance's gp3 root volume (holds Docker images, container logs, and the repo checkout)."
  type        = number
  default     = 60
}

variable "allowed_cidr" {
  description = "CIDR block allowed to reach SSH (22) and the demo frontend (8080), e.g. \"203.0.113.4/32\". No default on purpose -- you must scope this to your own IP."
  type        = string
  default     = "162.200.0.0/16"

  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "allowed_cidr must be a valid CIDR block, e.g. 203.0.113.4/32."
  }
}

variable "alert_email" {
  description = "Email address subscribed to the SNS topic that CloudWatch alarms notify: the instance status-check alarm (alerts.tf) and the per-service downtime alarms (monitoring.tf). The alarms themselves are always created and visible in the console either way; leave this unset (the default) to skip creating the SNS topic/subscription -- and thus the alarms' notification actions -- so cloning this deploy dir doesn't force anyone into SNS/email setup. AWS emails this address a subscription-confirmation link on the first apply; alerts won't arrive until it's clicked."
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be empty or look like a valid email address."
  }
}

variable "compose_profile" {
  description = "Which compose layer to run: \"core\" (compose.yaml only) or \"full\" (adds compose.full.yaml for Kafka/accounting/fraud-detection)."
  type        = string
  default     = "core"

  validation {
    condition     = contains(["core", "full"], var.compose_profile)
    error_message = "compose_profile must be either \"core\" or \"full\"."
  }
}

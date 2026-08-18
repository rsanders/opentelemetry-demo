variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westus2"
}

variable "project_name" {
  description = "Short name used to name Azure resources."
  type        = string
  default     = "azure-otel-demo"
}

variable "owner" {
  description = "Owner tag applied to all Azure resources."
  type        = string
  default     = "robert_sanders@outlook.com"
}

variable "allowed_cidr" {
  description = "CIDR permitted to access SSH and the demo HTTP endpoint."
  type        = string
  default     = "162.200.216.0/24"

  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "allowed_cidr must be a valid CIDR."
  }
}

variable "vm_size" {
  description = "VM SKU. Standard_B2s_v2 provides 2 vCPU and 8 GB RAM for the core Compose stack."
  type        = string
  default     = "Standard_B2s_v2"
}

variable "os_disk_size_gb" {
  description = "OS disk size for Docker images, containers, and the repository checkout."
  type        = number
  default     = 64
}

variable "compose_profile" {
  description = "Compose layer to run: core or full."
  type        = string
  default     = "core"

  validation {
    condition     = contains(["core", "full"], var.compose_profile)
    error_message = "compose_profile must be core or full."
  }
}

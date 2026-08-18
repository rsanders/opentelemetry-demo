locals {
  tags = {
    Project   = var.project_name
    Owner     = var.owner
    ManagedBy = "terraform"
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "ssh_private_key" {
  filename        = "${path.module}/../ansible/${var.project_name}-ssh.pem"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = "${var.project_name}-vm"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = var.vm_size
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.this.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.ssh.public_key_openssh
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = local.tags
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content = templatefile("${path.module}/templates/inventory.tpl.ini", {
    public_ip                  = azurerm_public_ip.this.ip_address
    ssh_key_path               = "${var.project_name}-ssh.pem"
    compose_profile            = var.compose_profile
    dcr_immutable_id           = jsondecode(azurerm_resource_group_template_deployment.otlp_dcr.output_content).immutableId.value
    logs_ingestion_endpoint    = azurerm_monitor_data_collection_endpoint.otlp.logs_ingestion_endpoint
    metrics_ingestion_endpoint = azurerm_monitor_data_collection_endpoint.otlp.metrics_ingestion_endpoint
  })
  file_permission = "0600"
}

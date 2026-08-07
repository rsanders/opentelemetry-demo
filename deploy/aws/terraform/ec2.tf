resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "ssh" {
  key_name   = "${var.project_name}-ssh"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_private_key" {
  filename        = "${path.module}/../ansible/${var.project_name}-ssh.pem"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance.id]
  key_name               = aws_key_pair.ssh.key_name
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
    # AWS's own guidance for containerized workloads: the app and collector
    # run in Docker, which is an extra network hop to the IMDS endpoint that
    # the default hop limit of 1 blocks.
    # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-new-instances.html
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "${var.project_name}"
  }
}

resource "aws_eip" "this" {
  domain   = "vpc"
  instance = aws_instance.this.id

  tags = {
    Name = "${var.project_name}"
  }
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content = templatefile("${path.module}/templates/inventory.tpl.ini", {
    public_ip         = aws_eip.this.public_ip
    ssh_key_path      = "${var.project_name}-ssh.pem"
    aws_region        = var.region
    compose_profile   = var.compose_profile
    app_log_group     = aws_cloudwatch_log_group.app.name
    otelcol_log_group = aws_cloudwatch_log_group.otelcol.name
  })
}

resource "aws_security_group" "instance" {
  name        = "${var.project_name}-instance"
  description = "SSH (for Ansible) and the demo frontend, both restricted to allowed_cidr."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-instance"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.instance.id
  description       = "SSH for Ansible provisioning"
  cidr_ipv4         = var.allowed_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "frontend" {
  security_group_id = aws_security_group.instance.id
  description       = "Demo frontend-proxy (ENVOY_PORT)"
  cidr_ipv4         = var.allowed_cidr
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.instance.id
  description       = "All outbound (image pulls, CloudWatch/X-Ray API calls)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

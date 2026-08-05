resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Some accounts (e.g. with org-wide GuardDuty runtime monitoring) have AWS
# automatically attach an interface VPC endpoint -- with its own ENI and a
# dedicated security group -- into every new VPC. Terraform doesn't manage
# any of that, but it blocks subnet/VPC deletion just the same. Clean up any
# such out-of-band endpoints and non-default security groups before we try
# to tear down the subnet/VPC, so `terraform destroy` doesn't hang or fail
# on a DependencyViolation for resources we never created.
resource "null_resource" "vpc_out_of_band_cleanup" {
  triggers = {
    vpc_id = aws_vpc.this.id
    region = var.region
  }

  depends_on = [aws_subnet.public]

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -eu
      VPC_ID="${self.triggers.vpc_id}"
      REGION="${self.triggers.region}"

      ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=vpc-endpoint-state,Values=available,pending" \
        --query 'VpcEndpoints[].VpcEndpointId' --output text)
      if [ -n "$ENDPOINT_IDS" ]; then
        echo "Deleting out-of-band VPC endpoint(s): $ENDPOINT_IDS"
        aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $ENDPOINT_IDS
        for i in $(seq 1 30); do
          REMAINING=$(aws ec2 describe-network-interfaces --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" --query 'length(NetworkInterfaces)' --output text)
          if [ "$REMAINING" = "0" ]; then
            echo "All ENIs cleared from $VPC_ID"
            break
          fi
          echo "Waiting for $REMAINING ENI(s) to detach from $VPC_ID..."
          sleep 5
        done
      fi

      SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)
      for sg in $SG_IDS; do
        echo "Deleting out-of-band security group: $sg"
        aws ec2 delete-security-group --region "$REGION" --group-id "$sg" || true
      done
    EOT
  }
}

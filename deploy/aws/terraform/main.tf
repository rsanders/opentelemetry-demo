provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      # AWS Resource Groups reads this key for tag-based grouping (the same
      # key AppRegistry/myApplications used to vend before it stopped taking
      # new customers on 2026-07-30) -- a plain static value works just as
      # well since nothing here depends on AppRegistry's ARN-based value.
      awsApplication = var.project_name
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

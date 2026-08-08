provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      Owner     = var.owner
      ManagedBy = "terraform"
      # AWS Resource Groups reads this key for tag-based grouping (the same
      # key AppRegistry/myApplications used to vend before it stopped taking
      # new customers on 2026-07-30) -- a plain static value works just as
      # well since nothing here depends on AppRegistry's ARN-based value.
      awsApplication = var.project_name

      # Provenance: which checkout/commit produced this infra. LastModified
      # is the commit's own timestamp rather than the apply's wall-clock
      # time, so it stays stable across repeat applies of the same commit
      # instead of diffing every resource's tags on every apply.
      GitRepo      = data.external.git_info.result.repo
      GitBranch    = data.external.git_info.result.branch
      GitCommit    = data.external.git_info.result.commit
      LastModified = data.external.git_info.result.commit_timestamp
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

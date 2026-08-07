terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.42 for aws_cloudwatch_metric_alarm's evaluation_criteria/
      # promql_criteria block (terraform/monitoring.tf) -- the only way to
      # alarm on metrics in CloudWatch's OTel/PromQL metric store, which
      # classic aws_cloudwatch_metric_alarm namespace/dimensions can't read
      # at all. A deliberate major-version bump from the previous ~> 5.0.
      version = ">= 6.42.0, < 7.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # CloudFormation-backed: Transaction Search's "enable" step
    # (awscc_xray_transaction_search_config, transaction-search.tf) has no
    # native hashicorp/aws resource until provider v6.46 (aws_xray_
    # trace_segment_destination/indexing_rule) -- v6 is a breaking major
    # version this repo isn't otherwise ready to move to, so awscc covers
    # just this one resource instead.
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
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

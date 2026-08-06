# Bootstraps CloudWatch Transaction Search, the account-wide prerequisite for
# the collector's otlphttp/traces exporter (iam.tf, "XRay" statement) to reach
# CloudWatch's OpenTelemetry traces endpoint at all. Without it, the endpoint
# rejects every request with "The OTLP API is supported with CloudWatch Logs
# as a Trace Segment Destination".
# https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Transaction-Search.html
#
# hashicorp/aws has no resource for the "enable" step itself until provider
# v6.46 (aws_xray_trace_segment_destination / aws_xray_indexing_rule) -- v6
# is a breaking major version bump this repo isn't otherwise making, so this
# uses hashicorp/awscc's CloudFormation-backed awscc_xray_transaction_search_config
# instead, which wraps AWS::XRay::TransactionSearchConfig and covers both the
# trace segment destination and the indexing percentage in one resource.
# https://registry.terraform.io/providers/hashicorp/awscc/latest/docs/resources/xray_transaction_search_config
#
# This is account/region-wide, not scoped to this deployment's own resources
# -- there's only one account-wide config to enable, not a per-stack object.
# That makes it safe to enable from both deploy/aws and deploy/aws-ecs at
# once (a real scenario: the two are meant to be run side by side for
# comparison, see the aws-ecs README): the awscc resource's underlying
# CloudFormation handler is an idempotent enable/update against the one thing
# that exists per account, so either stack applying its own copy converges on
# the same state rather than erroring; the resource policy below is scoped by
# a per-project policy_name, so both stacks' policies coexist rather than
# colliding. If both are applied, keep indexing_percentage equal across the
# two Terraform/CDK sources (both use AWS's own free-tier default, 1%) so
# neither's plan shows the other's value as drift to "fix".

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "transaction_search_logs" {
  statement {
    sid     = "TransactionSearchXRayAccess"
    actions = ["logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans:*",
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/application-signals/data:*",
    ]

    principals {
      type        = "Service"
      identifiers = ["xray.amazonaws.com"]
    }

    # Scopes the grant to X-Ray acting on this account's own behalf, per
    # AWS's example policy for this exact setup.
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:xray:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Lets X-Ray write the spans it receives into the aws/spans and
# application-signals log groups Transaction Search reads from. Whether those
# two log groups need to be pre-created isn't clearly documented -- AWS's own
# setup docs list logs:CreateLogGroup/CreateLogStream/PutRetentionPolicy on
# both as a prerequisite for whichever identity runs the enable steps, which
# reads as the API calls below creating them as a side effect rather than
# this Terraform needing an explicit aws_cloudwatch_log_group for either. If
# `terraform apply` fails here on AccessDenied for those actions, it's this
# stack's own deploying identity (AWS_PROFILE=skylab-sre-shared) that needs
# them, not the collector's instance role in iam.tf.
resource "aws_cloudwatch_log_resource_policy" "transaction_search" {
  policy_name     = "${var.project_name}-transaction-search"
  policy_document = data.aws_iam_policy_document.transaction_search_logs.json
}

# Percentage of ingested spans indexed as searchable trace summaries (the
# rest are still fully ingested as structured logs under Transaction Search,
# just not indexed for the search/analytics UI). 1% is AWS's own free-tier
# default and is enough given full-fidelity log ingestion already covers
# every span.
#
# prevent_destroy: this is an account-wide singleton, not something this
# stack necessarily created -- Create fails with Cloud Control API error
# AlreadyExists if Transaction Search was already enabled by anything else
# (another stack, the console, a teammate), which apply-with-retry.sh handles
# by importing the existing config instead of erroring out. On a shared
# account (AWS_PROFILE=skylab-sre-shared), that means `terraform destroy`
# (`make down`) could otherwise silently disable Transaction Search for
# everyone else using the account, not just this deployment. If it's
# genuinely this stack's to remove, `terraform state rm
# awscc_xray_transaction_search_config.this` first, then destroy.
resource "awscc_xray_transaction_search_config" "this" {
  indexing_percentage = 1

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_cloudwatch_log_resource_policy.transaction_search]
}

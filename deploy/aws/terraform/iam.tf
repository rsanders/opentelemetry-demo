data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.project_name}-instance"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "otel_export" {
  statement {
    sid = "CloudWatchLogs"
    # logs:PutLogEvents authorizes SigV4-signed requests to the CloudWatch
    # logs OTLP endpoint the same way it did the old awscloudwatchlogs
    # exporter -- both are ultimately CloudWatch Logs ingestion. Unchanged
    # from before: kept as-is for the OTLP path since AWS doesn't document a
    # different action set for it, and these were already sufficient.
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "${aws_cloudwatch_log_group.app.arn}:*",
      "${aws_cloudwatch_log_group.otelcol.arn}:*",
    ]
  }

  statement {
    sid     = "CloudWatchMetrics"
    actions = ["cloudwatch:PutMetricData"]
    # What the CloudWatch OTLP metrics endpoint authorizes SigV4-signed
    # requests against; it does not support resource-level restriction.
    resources = ["*"]
  }

  statement {
    sid = "XRay"
    # xray:PutTraceSegments authorizes SigV4-signed requests to the CloudWatch
    # (X-Ray) traces OTLP endpoint the same way it did the old awsxray
    # exporter -- both are the same X-Ray ingestion API underneath, just
    # different wire formats. Unchanged from before: kept as-is for the OTLP
    # path since AWS doesn't document a different action set for it. Separate
    # from these grants: the OTLP traces endpoint additionally requires
    # Transaction Search enabled on the account -- a manual, account-level
    # setting, not Terraform-managed here (verified active out-of-band via
    # `aws xray get-trace-segment-destination`).
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"] # X-Ray write actions do not support resource-level restriction
  }
}

resource "aws_iam_role_policy" "otel_export" {
  name   = "${var.project_name}-otel-export"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.otel_export.json
}

# Lets the instance read the LLM API key at deploy time (see secrets.tf and
# roles/otel_demo/tasks/main.yml's "Fetch LLM API key" task) without ever
# writing it to the rsynced repo copy or the compose .env file.
data "aws_iam_policy_document" "llm_secret" {
  count = var.enable_agent_layer ? 1 : 0
  statement {
    sid       = "ReadLLMApiKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.llm_api_key[0].arn]
  }
}

resource "aws_iam_role_policy" "llm_secret" {
  count  = var.enable_agent_layer ? 1 : 0
  name   = "${var.project_name}-llm-secret"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.llm_secret[0].json
}

# Pull-only access to the agent/chatbot/mcp images pushed by
# `make push-agentic-images` (see ecr.tf) -- these aren't published anywhere
# public, so the instance needs its own credentials to pull them.
data "aws_iam_policy_document" "agentic_ecr_pull" {
  count = var.enable_agent_layer ? 1 : 0

  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # token-vending action; does not support resource-level restriction
  }

  statement {
    sid = "ECRPull"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [for repo in aws_ecr_repository.agentic : repo.arn]
  }
}

resource "aws_iam_role_policy" "agentic_ecr_pull" {
  count  = var.enable_agent_layer ? 1 : 0
  name   = "${var.project_name}-agentic-ecr-pull"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.agentic_ecr_pull[0].json
}

# Lets Session Manager reach the instance (aws ssm start-session) without
# opening any inbound port -- an alternative to the SSH path Ansible uses.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.project_name}-instance"
  role = aws_iam_role.instance.name
}

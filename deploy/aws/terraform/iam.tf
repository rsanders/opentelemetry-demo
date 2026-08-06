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
    # Transaction Search enabled on the account -- bootstrapped in
    # transaction-search.tf.
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

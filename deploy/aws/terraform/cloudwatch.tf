# Destination for the collector's awscloudwatchlogs exporter. Metrics need no
# log group of their own -- they go to the CloudWatch OTLP metrics endpoint,
# not through EMF log lines.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/logs"
  retention_in_days = 14
}

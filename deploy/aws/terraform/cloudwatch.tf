resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/logs"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "collector" {
  name              = "/${var.project_name}/otelcol"
  retention_in_days = 14
}

# Per-service "is it down" alarms, backed by a custom metric namespace fed by
# a small script Ansible installs on the instance (roles/service_health) --
# not by CloudWatch itself, since none of Docker Compose's container state
# is otherwise visible to CloudWatch. See that role for what actually
# computes ServiceUp/ServiceRestartCount: it reads each container's Docker
# HEALTHCHECK (falling back to State.Running for the few containers that
# don't define one), plus a real HTTP GET for the handful of services that
# are genuinely HTTP. Kept on the classic PutMetricData/alarm path rather
# than the OTLP metrics endpoint used everywhere else in this deployment,
# because CloudWatch alarms need a stable, generally-available metric
# source -- the OTel metric store's PromQL-based alarms are a newer surface
# without confirmed Terraform provider support at the pinned aws provider
# version (see versions.tf).
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Every container compose.yaml/compose.full.yaml starts under the "core"
# profile (see terraform/variables.tf's compose_profile), by its
# container_name. Mirrors local.log_stream_services (cloudwatch.tf) plus the
# three support containers that don't get their own log stream there --
# kept as a separate list rather than folding those three in, since the log
# streams and these alarms are different concerns that happen to mostly
# overlap. Update alongside that list when a service is added/removed.
locals {
  monitored_services = concat(local.log_stream_services, ["astronomy-db", "valkey-cart", "otel-collector"])
}

resource "aws_cloudwatch_metric_alarm" "service_down" {
  for_each = toset(local.monitored_services)

  alarm_name        = "${var.project_name}-${each.value}-down"
  alarm_description = "${each.value} has reported unhealthy (or stopped reporting) for 15 minutes straight."

  namespace   = "${var.project_name}/services"
  metric_name = "ServiceUp"
  dimensions = {
    Service = each.value
  }

  # Maximum, not Average: a period only counts as "up" if at least one
  # check inside it succeeded, so a flapping service doesn't get averaged
  # into looking fine. 3 x 5m periods, all breaching, is 15 minutes down.
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # The health-check script (roles/service_health) runs every 60s; missing
  # data for a whole 5m period only happens if the script itself died or the
  # instance is unreachable -- both cases we want to alarm on, not ignore.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

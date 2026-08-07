# Optional email alert for the one signal that matters most on a
# single-instance deployment: is the instance still up. Entirely skipped
# (count = 0) when alert_email isn't set, so cloning this deploy dir doesn't
# force anyone into setting up SNS/email.
resource "aws_sns_topic" "alerts" {
  count = var.alert_email != "" ? 1 : 0
  name  = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Shared by every alarm in this deployment (below, and monitoring.tf's
# per-service ones): the alarms themselves are always created so they're
# visible in the console regardless of alert_email, but their actions list
# is empty -- not a reference to a topic that doesn't exist -- when there's
# no SNS topic to notify.
locals {
  alert_actions = var.alert_email != "" ? [aws_sns_topic.alerts[0].arn] : []
}

# StatusCheckFailed covers both the system (AWS-side) and instance
# (OS-side) status checks in one metric -- either one failing means the
# demo is unreachable. Published every 60s without needing detailed
# monitoring enabled. treat_missing_data = "breaching" because a healthy
# instance always reports this metric; missing data points mean the
# instance stopped reporting entirely, which is itself the failure.
#
# Always created, regardless of alert_email -- so it's visible (and
# alarm-state-queryable) in the console even with no notification channel
# configured. Only the SNS actions are conditional, via local.alert_actions.
resource "aws_cloudwatch_metric_alarm" "instance_status_check" {
  alarm_name        = "${var.project_name}-instance-status-check-failed"
  alarm_description = "${var.project_name} EC2 instance is failing its status checks -- the demo is likely unreachable."
  namespace         = "AWS/EC2"
  metric_name       = "StatusCheckFailed"
  dimensions = {
    InstanceId = aws_instance.this.id
  }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alert_actions
  ok_actions          = local.alert_actions
}

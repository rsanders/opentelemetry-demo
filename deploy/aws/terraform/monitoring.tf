# Per-service "is it down" alarms. The metrics these read (deploy.service_up,
# deploy.service_restart_count) are pushed by a script Ansible installs on the
# instance (roles/service_health) straight into the otel-collector's own OTLP
# receiver -- the same one every app service already sends to -- so they ride
# the collector's existing metrics pipeline (resourcedetection, the
# CloudWatch-metrics filter, batching) out to the same otlphttp/metrics
# exporter as everything else. See that role for what actually computes them:
# Docker's own HEALTHCHECK status (falling back to State.Running for the few
# containers that don't define one), plus a real HTTP GET for the handful of
# services that are genuinely HTTP.
#
# That means these metrics only exist in CloudWatch's OTel/PromQL metric
# store, not a classic namespace -- so alarming on them needs a PromQL
# alarm (evaluation_criteria/promql_criteria below), not the
# namespace/dimensions/statistic form of aws_cloudwatch_metric_alarm. That
# block needs hashicorp/aws >= 6.42 (see versions.tf).
#
# A PromQL alarm's query simply stops returning a time series if nothing is
# reporting it -- that reads as *recovering*, not breaching (see the AWS
# PromQL-alarms doc), unlike a classic alarm's treat_missing_data =
# "breaching". `or absent_over_time(...)` below is the standard Prometheus
# idiom to fold "stopped reporting" back into the query's result instead:
# the `== 0` branch matches an explicit failure, and `absent_over_time`
# produces its own single time series (carrying the same
# @resource.service.name label, since that's an equality matcher on the
# vector selector inside it) whenever the metric hasn't been seen at all in
# the lookback window -- covering the check script or the otel-collector
# container itself going down, not just an explicit unhealthy report. The
# instance_status_check alarm in alerts.tf (EC2 StatusCheckFailed) still
# exists as a coarser backstop for "the whole instance is dead."

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
  # Always created (one per service) regardless of alert_email, so they're
  # visible in the console with no notification channel configured -- only
  # the actions are conditional, via alerts.tf's local.alert_actions (same
  # SNS topic instance_status_check uses, not a second one).
  for_each = toset(local.monitored_services)

  alarm_name        = "${var.project_name}-${each.value}-down"
  alarm_description = "${each.value} has reported unhealthy, or stopped reporting at all, for 5 minutes straight."

  evaluation_criteria {
    promql_criteria {
      # @resource.service.name, not a bare label -- see
      # roles/service_health/files/check.py, which sets service.name as an
      # OTLP *resource* attribute (one ResourceMetrics per service) to match
      # how every other service's own telemetry is labeled. The
      # absent_over_time window (3m = 3 push cycles, the script runs every
      # 60s) tolerates one missed push without flapping, while still being
      # comfortably under the 5-minute pending_period below.
      query           = <<-EOT
        {"deploy.service_up", "@resource.service.name"="${each.value}"} == 0
        or
        absent_over_time({"deploy.service_up", "@resource.service.name"="${each.value}"}[3m])
      EOT
      pending_period  = 300 # 5 minutes
      recovery_period = 120
    }
  }
  evaluation_interval = 60 # matches the check script's push interval

  alarm_actions = local.alert_actions
  ok_actions    = local.alert_actions
}

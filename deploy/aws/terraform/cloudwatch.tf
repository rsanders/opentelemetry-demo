# Destination for the collector's per-service otlphttp/logs/* exporters.
# Metrics need no log group of their own -- they go to the CloudWatch OTLP
# metrics endpoint, not through EMF log lines. The collector's own
# self-telemetry logs go to aws_cloudwatch_log_group.otelcol instead (below),
# kept separate so they don't turn up in searches/correlations scoped to this
# group's app logs.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/logs"
  retention_in_days = 14
}

# Unlike the awscloudwatchlogs exporter these replaced (which auto-created
# its log stream on first write), the CloudWatch logs OTLP endpoint returns a
# hard 400 "The specified log stream does not exist" if the stream isn't
# already there -- confirmed by exporting into this log group with streams
# that didn't exist yet. So the streams the collector's per-service exporters
# write into (see the x-aws-log-stream header on each otlphttp/logs/* in
# otelcol-config-extras-aws.yml.j2) have to be created out-of-band, here.
#
# This list must stay in sync with log_stream_services in that same Jinja
# template (and with its hand-expanded copy in the sibling
# deploy/aws-ecs/cdk/files/otelcol-config-extras-aws.yml) -- a service
# missing from here will hit the same "stream does not exist" error and get
# its logs dropped, even though it has a route to the right exporter.
locals {
  log_stream_services = [
    "ad", "cart", "checkout", "currency", "email", "frontend", "frontend-proxy",
    "image-provider", "load-generator", "payment", "product-catalog", "quote",
    "recommendation", "shipping", "flagd", "flagd-ui", "telemetry-docs",
  ]
}

resource "aws_cloudwatch_log_stream" "app" {
  for_each       = toset(concat(local.log_stream_services, ["other"]))
  name           = each.value
  log_group_name = aws_cloudwatch_log_group.app.name
}

# The collector's own self-telemetry (service.name "otelcol-contrib", see the
# otlphttp/logs/otel-collector exporter in otelcol-config-extras-aws.yml.j2),
# in its own log group rather than a stream under aws_cloudwatch_log_group.app
# -- otherwise CloudWatch Logs Insights queries/correlations scoped to that
# group (e.g. via aws.log.group.names on traces) would also pull in the
# collector's internal debug-level logging.
resource "aws_cloudwatch_log_group" "otelcol" {
  name              = "/${var.project_name}/otelcol"
  retention_in_days = 14
  # Overrides the provider's default_tags (main.tf), so this group -- and
  # only this group -- shows up under its own Application in Resource
  # Groups/myApplications rather than the shared "${var.project_name}"
  # Application every other resource on the instance falls under.
  tags = {
    awsApplication = "${var.project_name}-monitoring"
  }
}

resource "aws_cloudwatch_log_stream" "otelcol" {
  name           = "otel-collector"
  log_group_name = aws_cloudwatch_log_group.otelcol.name
}

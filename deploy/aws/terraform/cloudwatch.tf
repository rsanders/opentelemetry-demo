# Destination for the collector's per-service otlphttp/logs/* exporters.
# Metrics need no log group of their own -- they go to the CloudWatch OTLP
# metrics endpoint, not through EMF log lines.
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
  for_each       = toset(concat(local.log_stream_services, ["otel-collector", "other"]))
  name           = each.value
  log_group_name = aws_cloudwatch_log_group.app.name
}

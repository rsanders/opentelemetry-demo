#!/bin/bash
# Polls every container compose.yaml/compose.full.yaml starts (by its fixed
# container_name) and reports two things per service to CloudWatch:
#
#   ServiceUp (0/1)      - Docker's own HEALTHCHECK status where the service
#                          defines one, falling back to State.Running for
#                          the few that don't (cart, flagd, otel-collector).
#                          For the handful of services that are genuinely
#                          HTTP, a real GET against the path in HTTP_CHECKS
#                          additionally has to succeed -- Docker health alone
#                          only proves the process is up, not that it's
#                          actually serving.
#   ServiceRestartCount  - Docker's RestartCount, which increments each time
#                          the daemon auto-restarts a container under its
#                          `restart: unless-stopped` policy (see compose.yaml)
#                          after it exits on its own -- not on a manual
#                          `docker restart`/`compose restart`.
#
# Pushed two ways: PutMetricData in a project-specific classic namespace,
# which terraform/monitoring.tf's alarms fire against directly, and (best
# effort) as StatsD gauges to the CloudWatch agent's statsd receiver on
# 127.0.0.1:8125 (see roles/cloudwatch_agent), which forwards them into the
# OTel metric store via OTLP alongside the box's host-infra metrics.
#
# PROJECT_NAME and AWS_REGION come from /etc/otel-demo-monitoring.env
# (EnvironmentFile= on the systemd unit) rather than being templated
# straight into this script, so the script itself can be deployed verbatim
# and inspected/tested without Ansible in the loop.
set -uo pipefail

: "${PROJECT_NAME:?PROJECT_NAME must be set (see /etc/otel-demo-monitoring.env)}"
: "${AWS_REGION:?AWS_REGION must be set (see /etc/otel-demo-monitoring.env)}"

NAMESPACE="${PROJECT_NAME}/services"

SERVICES=(
  ad cart checkout currency email frontend frontend-proxy image-provider
  load-generator payment product-catalog quote recommendation shipping
  flagd flagd-ui telemetry-docs astronomy-db valkey-cart otel-collector
)

# service -> "PORT_SOURCE:path". PORT_SOURCE is either the name of an env
# var read out of the container's own environment, or a literal port number
# prefixed with "=" for the few services whose relevant port isn't one of
# compose.yaml's published ${..._PORT} variables (flagd's health endpoint
# runs on its default management port, 8014, which this repo's compose.yaml
# never overrides or publishes -- https://flagd.dev/reference/monitoring/).
# Every other service here is gRPC or plain TCP and relies on the Docker
# health/running check above instead.
declare -A HTTP_CHECKS=(
  [frontend]="FRONTEND_PORT:/"
  [frontend-proxy]="ENVOY_ADMIN_PORT:/ready"
  [image-provider]="IMAGE_PROVIDER_PORT:/status"
  [flagd-ui]="FLAGD_UI_PORT:/"
  [telemetry-docs]="TELEMETRY_DOCS_PORT:/"
  [flagd]="=8014:/healthz"
)

metric_data="["
first=1

for svc in "${SERVICES[@]}"; do
  up=0
  restarts=0

  state=$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null || true)
  if [ -n "$state" ]; then
    restarts=$(docker inspect -f '{{.RestartCount}}' "$svc" 2>/dev/null || echo 0)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$svc" 2>/dev/null || echo n/a)
    if [ "$health" = "n/a" ]; then
      [ "$state" = "running" ] && up=1
    else
      [ "$health" = "healthy" ] && up=1
    fi

    if [ "$up" = "1" ] && [ -n "${HTTP_CHECKS[$svc]:-}" ]; then
      port_source="${HTTP_CHECKS[$svc]%%:*}"
      path="${HTTP_CHECKS[$svc]#*:}"
      if [ "${port_source:0:1}" = "=" ]; then
        port="${port_source:1}"
      else
        port=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$svc" 2>/dev/null \
          | awk -F= -v k="$port_source" '$1==k{print $2; exit}')
      fi
      ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$svc" 2>/dev/null)
      if [ -n "$port" ] && [ -n "$ip" ]; then
        curl -fsS -m 5 -o /dev/null "http://${ip}:${port}${path}" || up=0
      else
        up=0
      fi
    fi
  fi

  [ "$first" = 1 ] || metric_data+=","
  first=0
  metric_data+="{\"MetricName\":\"ServiceUp\",\"Dimensions\":[{\"Name\":\"Service\",\"Value\":\"${svc}\"}],\"Value\":${up},\"Unit\":\"Count\"}"
  metric_data+=",{\"MetricName\":\"ServiceRestartCount\",\"Dimensions\":[{\"Name\":\"Service\",\"Value\":\"${svc}\"}],\"Value\":${restarts},\"Unit\":\"Count\"}"

  {
    printf '%s.service.%s.up:%s|g' "$PROJECT_NAME" "$svc" "$up" > "/dev/udp/127.0.0.1/8125"
    printf '%s.service.%s.restart_count:%s|g' "$PROJECT_NAME" "$svc" "$restarts" > "/dev/udp/127.0.0.1/8125"
  } 2>/dev/null || true
done

metric_data+="]"

aws cloudwatch put-metric-data \
  --region "$AWS_REGION" \
  --namespace "$NAMESPACE" \
  --metric-data "$metric_data"

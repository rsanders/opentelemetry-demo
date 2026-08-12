#!/usr/bin/env python3
# Polls every container compose.yaml/compose.full.yaml starts (by its fixed
# container_name) and pushes two OTLP gauge metrics per service straight into
# the otel-collector's own OTLP/HTTP receiver -- the same one every app
# service already sends to (see src/otel-collector/otelcol-config.yml's
# `otlp` receiver) -- rather than calling a CloudWatch API directly. That
# way these metrics ride the collector's existing metrics pipeline
# (resourcedetection, the CloudWatch-metrics filter, batching) out to the
# same otlphttp/metrics exporter as everything else, and pick up the same
# host/cloud resource attributes automatically. Each service gets its own
# OTLP ResourceMetrics entry with service.name (and, where the container sets
# one, the rest of its OTEL_RESOURCE_ATTRIBUTES) as *resource* attributes --
# not datapoint labels -- to match how that service's own telemetry is
# labeled. terraform/monitoring.tf's alarms query these back out with PromQL
# against CloudWatch's OTel metric store; there's no classic-namespace copy.
#
#   deploy.service_up             - Docker's own HEALTHCHECK status where the
#                                    service defines one, falling back to
#                                    State.Running for the few that don't
#                                    (cart, flagd, otel-collector). For the
#                                    handful of services that are genuinely
#                                    HTTP, a real GET against the path in
#                                    HTTP_CHECKS additionally has to succeed --
#                                    Docker health alone only proves the
#                                    process is up, not that it's serving.
#   deploy.service_restart_count  - Docker's RestartCount, which increments
#                                    each time the daemon auto-restarts a
#                                    container under its `restart:
#                                    unless-stopped` policy (see compose.yaml)
#                                    after it exits on its own -- not on a
#                                    manual `docker restart`/`compose
#                                    restart`.
#
# Built with the stdlib (json/subprocess/urllib) rather than the AWS CLI or
# boto3 -- this script no longer talks to AWS at all, so it needs neither.
# If the otel-collector container isn't up, or the push fails, this just
# skips the cycle (logging to stderr) rather than falling back to some other
# path -- see terraform/monitoring.tf's comment on what that means for
# alarms.
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

SERVICES = [
    "ad", "cart", "checkout", "currency", "email", "frontend", "frontend-proxy",
    "image-provider", "load-generator", "payment", "product-catalog", "quote",
    "recommendation", "shipping", "flagd", "flagd-ui", "telemetry-docs",
    "astronomy-db", "valkey-cart", "otel-collector",
]

# service -> (port_source, path). port_source is either the name of an env
# var read out of the container's own environment, or a literal int for the
# one service whose relevant port isn't one of compose.yaml's published
# ${..._PORT} variables: flagd's health endpoints run on its default
# management port, 8014, which this repo's compose.yaml never overrides or
# publishes (https://flagd.dev/reference/monitoring/). Every other service
# here is gRPC or plain TCP and relies on the Docker health/running check
# above instead. frontend is the other odd one: compose.yaml injects
# FRONTEND_PORT into its container as plain PORT (the Node convention), so
# its own environment never has a FRONTEND_PORT key.
HTTP_CHECKS = {
    "frontend": ("PORT", "/"),
    "frontend-proxy": ("ENVOY_ADMIN_PORT", "/ready"),
    "image-provider": ("IMAGE_PROVIDER_PORT", "/status"),
    "flagd-ui": ("FLAGD_UI_PORT", "/"),
    "telemetry-docs": ("TELEMETRY_DOCS_PORT", "/"),
    "flagd": (8014, "/healthz"),
}

OTLP_RECEIVER_PORT = 4318


def docker_inspect(name):
    try:
        out = subprocess.run(
            ["docker", "inspect", name],
            capture_output=True, text=True, timeout=10, check=True,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return None
    try:
        return json.loads(out.stdout)[0]
    except (json.JSONDecodeError, IndexError):
        return None


def container_env(info):
    return dict(kv.split("=", 1) for kv in info["Config"]["Env"] if "=" in kv)


def container_ip(info):
    networks = info.get("NetworkSettings", {}).get("Networks", {})
    for net in networks.values():
        if net.get("IPAddress"):
            return net["IPAddress"]
    return None


def http_ok(ip, port, path, timeout=5):
    try:
        with urllib.request.urlopen(f"http://{ip}:{port}{path}", timeout=timeout) as resp:
            return 200 <= resp.status < 400
    except (urllib.error.URLError, OSError, ValueError):
        return False


# OTEL_RESOURCE_ATTRIBUTES is a comma-separated "key=value,key2=value2" list,
# already fully resolved by compose (unlike re-parsing .env, which would
# still have ${...} placeholders in it) -- e.g. see compose.yaml's `cart`
# service, or .env's own OTEL_RESOURCE_ATTRIBUTES definition.
def parse_resource_attributes(raw):
    attrs = {}
    for pair in raw.split(","):
        if "=" in pair:
            key, _, value = pair.partition("=")
            key, value = key.strip(), value.strip()
            if key and value:
                attrs[key] = value
    return attrs


def otlp_gauge(name, value):
    return {
        "name": name,
        "gauge": {
            "dataPoints": [
                {"timeUnixNano": str(time.time_ns()), "asInt": str(value)}
            ]
        },
    }


def check_service(svc):
    info = docker_inspect(svc)
    up = 0
    restarts = 0
    resource_attrs = {"service.name": svc}

    if info is not None:
        state = info.get("State", {})
        restarts = info.get("RestartCount", 0)
        health = state.get("Health", {}).get("Status")
        up = 1 if (health == "healthy" or (health is None and state.get("Running"))) else 0

        env = container_env(info)
        resource_attrs.update(parse_resource_attributes(env.get("OTEL_RESOURCE_ATTRIBUTES", "")))

        if up and svc in HTTP_CHECKS:
            port_source, path = HTTP_CHECKS[svc]
            port = port_source if isinstance(port_source, int) else env.get(port_source)
            ip = container_ip(info)
            if not (port and ip and http_ok(ip, port, path)):
                up = 0

    return resource_attrs, up, restarts


def build_payload():
    resource_metrics = []
    for svc in SERVICES:
        resource_attrs, up, restarts = check_service(svc)
        resource_metrics.append({
            "resource": {
                "attributes": [
                    {"key": k, "value": {"stringValue": v}} for k, v in resource_attrs.items()
                ]
            },
            "scopeMetrics": [{
                "scope": {"name": "otel-demo-service-health"},
                "metrics": [
                    otlp_gauge("deploy.service_up", up),
                    otlp_gauge("deploy.service_restart_count", restarts),
                ],
            }],
        })
    return {"resourceMetrics": resource_metrics}


def main():
    collector = docker_inspect("otel-collector")
    collector_ip = container_ip(collector) if collector else None
    if not collector_ip:
        print("otel-collector container not found/not running; skipping this cycle", file=sys.stderr)
        return 0

    payload = json.dumps(build_payload()).encode()
    req = urllib.request.Request(
        f"http://{collector_ip}:{OTLP_RECEIVER_PORT}/v1/metrics",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    except (urllib.error.URLError, OSError) as e:
        print(f"failed to push metrics to otel-collector: {e}", file=sys.stderr)
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Generate Azure Portal dashboard property documents for the Azure demo stack."""

import argparse
import json
from pathlib import Path


SERVICES = (
    "otel-collector",
    "flagd",
    "astronomy-db",
    "product-catalog",
    "shipping",
    "valkey-cart",
    "cart",
    "currency",
    "email",
    "payment",
    "checkout",
    "ad",
    "quote",
    "recommendation",
    "image-provider",
    "frontend",
    "flagd-ui",
    "telemetry-docs",
    "frontend-proxy",
    "load-generator",
)

FOCUSED_METRICS = {
    "ad": ("demo_ad_served_total", "demo.ad.requests"),
    "astronomy-db": ("postgresql.operations", "postgresql.rows", "postgresql.blocks_read"),
    "cart": ("demo.cart.add_item.latency", "demo.cart.get_cart.latency"),
    "checkout": ("rpc.client.call.duration", "http.client.request.duration"),
    "currency": ("demo.exchange.conversions_counter",),
    "email": ("demo.notification.confirmations",),
    "flagd": ("feature_flag_flagd_impression_total", "feature_flag_flagd_result_reason_total"),
    "flagd-ui": ("container.cpu.utilization", "container.memory.percent"),
    "frontend": ("http.server.request.duration", "v8js.gc.duration"),
    "frontend-proxy": ("envoy_http_downstream_rq_time", "envoy_cluster_upstream_rq_time"),
    "image-provider": ("traces.span.metrics.calls", "traces.span.metrics.duration"),
    "load-generator": ("k6.http_reqs", "k6.http_req_duration", "k6.browser_http_req_failed.total"),
    "otel-collector": ("otelcol_receiver_accepted_metric_points", "otelcol_receiver_failed_metric_points", "otelcol_exporter_queue_size"),
    "payment": ("demo.payment.transactions", "v8js.gc.duration"),
    "product-catalog": ("db.client.operation.duration", "rpc.server.call.duration"),
    "quote": ("quotes",),
    "recommendation": ("demo.recommendation.requests", "traces.span.metrics.duration"),
    "shipping": ("demo.shipping.items_shipped", "http.server.request.duration"),
    "telemetry-docs": ("traces.span.metrics.calls", "traces.span.metrics.duration"),
    "valkey-cart": ("redis.cpu.time", "redis.clients.connected", "redis.memory.used"),
}


def query_part(workspace_id, title, subtitle, query, x, y, chart="Line", dimensions=None):
    inputs = [
        {"name": "resourceTypeMode", "isOptional": True},
        {"name": "ComponentId", "value": workspace_id, "isOptional": True},
        {"name": "Scope", "value": {"resourceIds": [workspace_id]}, "isOptional": True},
        {"name": "PartId", "value": f"otel-demo-{x}-{y}", "isOptional": True},
        {"name": "Version", "value": "2.0", "isOptional": True},
        {"name": "TimeRange", "isOptional": True},
        {"name": "DashboardId", "isOptional": True},
        {"name": "Query", "value": query, "isOptional": True},
        {"name": "ControlType", "value": "AnalyticsGrid" if chart == "Grid" else "FrameControlChart", "isOptional": True},
        {"name": "PartTitle", "value": title, "isOptional": True},
        {"name": "PartSubTitle", "value": subtitle, "isOptional": True},
        {"name": "IsQueryContainTimeRange", "value": True, "isOptional": True},
    ]
    if chart != "Grid":
        inputs.extend((
            {"name": "SpecificChart", "value": chart, "isOptional": True},
            {"name": "Dimensions", "value": dimensions, "isOptional": True},
            {"name": "LegendOptions", "value": {"isEnabled": True, "position": "Bottom"}, "isOptional": True},
        ))
    return {
        "position": {"x": x, "y": y, "colSpan": 8, "rowSpan": 5},
        "metadata": {
            "inputs": inputs,
            "type": "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart",
        },
    }


def dashboard(service, workspace_id, app_insights_id):
    role = service.replace('"', '\\"')
    time_axis = {"name": "TimeGenerated", "type": "datetime"}
    role_filter = f'AppRoleName == "{role}" or AppRoleName endswith ".{role}"'
    rate_query = f'''AppRequests
| where TimeGenerated > ago(6h) and ({role_filter})
| summarize RequestsPerSecond=sum(ItemCount)/60.0 by bin(TimeGenerated, 1m)
| order by TimeGenerated asc'''
    error_query = f'''AppRequests
| where TimeGenerated > ago(6h) and ({role_filter})
| summarize Requests=sum(ItemCount), Failures=sumif(ItemCount, Success == false) by bin(TimeGenerated, 1m)
| extend ErrorPercent=iff(Requests == 0, 0.0, 100.0 * todouble(Failures) / Requests)
| project TimeGenerated, ErrorPercent
| order by TimeGenerated asc'''
    latency_query = f'''AppRequests
| where TimeGenerated > ago(6h) and ({role_filter})
| summarize P50Milliseconds=percentile(DurationMs, 50), P95Milliseconds=percentile(DurationMs, 95), P99Milliseconds=percentile(DurationMs, 99) by bin(TimeGenerated, 1m)
| order by TimeGenerated asc'''
    resource_query = f'''AppMetrics
| where TimeGenerated > ago(6h) and ({role_filter})
| where Name in ("container.cpu.utilization", "container.memory.percent")
| summarize Value=avg(Sum) by bin(TimeGenerated, 1m), Name
| order by TimeGenerated asc'''
    failure_query = f'''AppRequests
| where TimeGenerated > ago(24h) and ({role_filter}) and Success == false
| project TimeGenerated, OperationName, ResultCode, DurationMs, Properties
| order by TimeGenerated desc
| take 100'''
    metric_names = ", ".join(json.dumps(name) for name in FOCUSED_METRICS[service])
    if service in ("astronomy-db", "valkey-cart"):
        metric_role_filter = "true"
    elif service == "frontend-proxy":
        metric_role_filter = f'({role_filter}) or AppRoleName == "opentelemetry-demo.envoy"'
    elif service == "otel-collector":
        metric_role_filter = f'({role_filter}) or AppRoleName endswith ".otelcol-contrib"'
    else:
        metric_role_filter = role_filter
    metrics_query = f'''AppMetrics
| where TimeGenerated > ago(6h) and ({metric_role_filter})
| where Name in ({metric_names})
| summarize Value=sum(Sum) by bin(TimeGenerated, 1m), Name
| order by TimeGenerated asc'''

    line = lambda *ys: {"xAxis": time_axis, "yAxis": [{"name": y, "type": "real"} for y in ys], "aggregation": "Average"}
    split_line = lambda y: {"xAxis": time_axis, "yAxis": [{"name": y, "type": "real"}], "splitBy": [{"name": "Name", "type": "string"}], "aggregation": "Average"}
    parts = [
        {
            "position": {"x": 0, "y": 0, "colSpan": 16, "rowSpan": 2},
            "metadata": {
                "inputs": [],
                "type": "Extension/HubsExtension/PartType/MarkdownPart",
                "settings": {"content": {"settings": {
                    "title": f"OpenTelemetry Demo: {service}",
                    "subtitle": "Application Insights / Log Analytics",
                    "content": f"Request golden signals and service telemetry for `{service}` over the last 6 hours. [Open Application Insights](https://portal.azure.com/#@/resource{app_insights_id}/overview).",
                }}},
            },
        },
        query_part(workspace_id, "Request rate", "Requests per second", rate_query, 0, 2, dimensions=line("RequestsPerSecond")),
        query_part(workspace_id, "Error rate", "Failed requests as a percentage", error_query, 8, 2, dimensions=line("ErrorPercent")),
        query_part(workspace_id, "Request latency", "P50, P95, and P99 in milliseconds", latency_query, 0, 7, dimensions=line("P50Milliseconds", "P95Milliseconds", "P99Milliseconds")),
        query_part(workspace_id, "Container resources", "CPU and memory telemetry", resource_query, 8, 7, dimensions=split_line("Value")),
        query_part(workspace_id, "Recent failed requests", "Most recent 100 failures", failure_query, 0, 12, chart="Grid"),
        query_part(workspace_id, "Focused service metrics", "Domain or runtime signals relevant to this service", metrics_query, 8, 12, dimensions=split_line("Value")),
    ]
    return {"lenses": [{"order": 0, "parts": parts}], "metadata": {"model": {}}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--application-insights-id", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for service in SERVICES:
        path = args.output_dir / f"otel-demo-{service}.json"
        path.write_text(json.dumps(dashboard(service, args.workspace_id, args.application_insights_id), indent=2) + "\n")


if __name__ == "__main__":
    main()

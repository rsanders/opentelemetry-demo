#!/usr/bin/env python3
"""Generate native-OTLP Azure Workbook resources for every demo service."""

import argparse
import json
import uuid
from pathlib import Path


SERVICES = (
    "otel-collector", "flagd", "astronomy-db", "product-catalog", "shipping",
    "valkey-cart", "cart", "currency", "email", "payment", "checkout", "ad",
    "quote", "recommendation", "image-provider", "frontend", "flagd-ui",
    "telemetry-docs", "frontend-proxy", "load-generator",
)

WORKBOOK_NAMESPACE = uuid.UUID("856887da-b54e-4d6f-b470-f453e809d00d")

FOCUSED_METRICS = {
    "ad": ('sum by (category) ({__name__="demo_ad_served_total", "service.name"="ad"})', "Ads served by category"),
    "astronomy-db": ('sum by (operation) ({__name__="postgresql.operations"})', "PostgreSQL operations by type"),
    "cart": ('{__name__="demo.cart.add_item.latency", "service.name"="cart"}', "Add-item operation latency"),
    "checkout": ('sum({__name__="traces.span.metrics.calls", "service.name"="checkout"})', "Checkout span calls"),
    "currency": ('sum by ("demo.exchange.to") ({__name__="demo.exchange.conversions_counter", "service.name"="currency"})', "Conversions by target currency"),
    "email": ('sum({__name__="demo.notification.confirmations", "service.name"="email"})', "Order confirmations"),
    "flagd": ('sum by (feature_flag_key, feature_flag_result_variant) ({__name__="feature_flag_flagd_impression_total", "service.name"="flagd"})', "Flag evaluations by result"),
    "flagd-ui": ('sum({__name__="container.network.io.usage.rx_bytes", "service.name"="flagd-ui"})', "Container network receive bytes"),
    "frontend": ('{__name__="v8js.gc.duration", "service.name"="frontend"}', "JavaScript garbage collection duration"),
    "frontend-proxy": ('sum({__name__="envoy_http_downstream_rq_time", "service.name"="envoy"})', "Envoy downstream request time"),
    "image-provider": ('sum by (state) ({__name__="nginx.connections_current"})', "Nginx connections by state"),
    "load-generator": ('sum by (status) ({__name__="k6.http_reqs", "service.name"="load-generator"})', "Generated HTTP requests by status"),
    "otel-collector": ('sum by (receiver) ({__name__="otelcol_receiver_accepted_metric_points", "service.name"="otelcol-contrib"})', "Collector metric throughput by receiver"),
    "payment": ('sum by ("demo.payment.currency") ({__name__="demo.payment.transactions", "service.name"="payment"})', "Payment transactions by currency"),
    "product-catalog": ('sum({__name__="db.client.operation.duration", "service.name"="product-catalog"})', "Database client operation duration"),
    "quote": ('sum by (number_of_items) ({__name__="quotes", "service.name"="quote"})', "Quotes by item count"),
    "recommendation": ('sum by ("recommendation.type") ({__name__="demo.recommendation.requests", "service.name"="recommendation"})', "Recommendation requests by type"),
    "shipping": ('sum({__name__="demo.shipping.items_shipped", "service.name"="shipping"})', "Items shipped"),
    "telemetry-docs": ('sum({__name__="traces.span.metrics.calls", "service.name"="telemetry-docs"})', "Telemetry-docs span calls"),
    "valkey-cart": ('{__name__="redis.clients.connected"}', "Valkey connected clients"),
}


def span_scope(service):
    if service == "astronomy-db":
        return 'Kind == "Client" and DependencyType == "DB" and Name == "astronomy-db"'
    if service == "valkey-cart":
        return 'Kind == "Client" and DependencyType == "redis" and (Target startswith "valkey-cart" or Name startswith "valkey-cart")'
    kind = "Client" if service == "load-generator" else "Server"
    return f'ServiceNamespace == "opentelemetry-demo" and ServiceName == "{service}" and Kind == "{kind}"'


def log_scope(service):
    name = "otelcol-contrib" if service == "otel-collector" else service
    return f'ServiceName == "{name}"'


def markdown(name, body):
    return {"type": 1, "name": name, "content": {"json": body}}


def time_parameter():
    return {
        "type": 9,
        "name": "time-range",
        "content": {
            "version": "KqlParameterItem/1.0",
            "parameters": [{
                "id": "7ad0bc93-b2d5-4ddd-8885-f14eeae69a1d",
                "version": "KqlParameterItem/1.0",
                "name": "TimeRange",
                "label": "Time range",
                "type": 4,
                "isRequired": True,
                "value": {"durationMs": 21600000},
                "typeSettings": {
                    "selectableValues": [
                        {"durationMs": 3600000}, {"durationMs": 21600000},
                        {"durationMs": 43200000}, {"durationMs": 86400000},
                        {"durationMs": 172800000}, {"durationMs": 604800000},
                    ],
                    "allowCustom": True,
                },
            }],
            "style": "pills",
            "queryType": 0,
            "resourceType": "microsoft.operationalinsights/workspaces",
        },
    }


def kql_item(name, title, query, workspace_id, visualization="timechart", width="50"):
    return {
        "type": 3,
        "name": name,
        "content": {
            "version": "KqlItem/1.0",
            "title": title,
            "query": query,
            "size": 0,
            "timeContextFromParameter": "TimeRange",
            "queryType": 0,
            "resourceType": "microsoft.operationalinsights/workspaces",
            "crossComponentResources": [workspace_id],
            "visualization": visualization,
        },
        "customWidth": width,
    }


def prom_item(name, title, query, monitor_workspace_id, width="50"):
    provider_query = json.dumps({
        "version": "PrometheusQueryProvider/1.0",
        "customEndpoint": False,
        "queryText": query,
        "type": "query_range",
    }, separators=(",", ":"))
    return {
        "type": 3,
        "name": name,
        "content": {
            "version": "KqlItem/1.0",
            "title": title,
            "query": provider_query,
            "size": 0,
            "timeContextFromParameter": "TimeRange",
            "queryType": 16,
            "resourceType": "microsoft.monitor/accounts",
            "crossComponentResources": [monitor_workspace_id],
            "visualization": "timechart",
        },
        "customWidth": width,
    }


def standard_span_items(service, workspace_id):
    scope = span_scope(service)
    common = f'OTelSpans\n| where TimeGenerated {{TimeRange}}\n| where {scope}'
    return [
        kql_item("activity-rate", "Activity rate (spans/s)", common + '\n| summarize SpansPerSecond=count()/60.0 by bin(TimeGenerated, 1m), Name\n| order by TimeGenerated asc', workspace_id),
        kql_item("error-rate", "Error rate (%)", common + '\n| summarize Total=count(), Failed=countif(Success == false or StatusCode =~ "Error") by bin(TimeGenerated, 1m)\n| extend ErrorPercent=100.0*todouble(Failed)/Total\n| project TimeGenerated, ErrorPercent\n| order by TimeGenerated asc', workspace_id),
        kql_item("latency", "Latency percentiles (ms)", common + '\n| summarize P50Milliseconds=percentile(DurationMs,50), P95Milliseconds=percentile(DurationMs,95), P99Milliseconds=percentile(DurationMs,99) by bin(TimeGenerated,1m)\n| order by TimeGenerated asc', workspace_id, width="100"),
    ]


def collector_items(monitor_workspace_id):
    return [
        prom_item("collector-throughput", "Collector accepted telemetry", 'sum by (__name__, receiver) ({__name__="otelcol_receiver_accepted_metric_points", "service.name"="otelcol-contrib"})', monitor_workspace_id),
        prom_item("collector-queue", "Exporter queue size", 'sum by (exporter) ({__name__="otelcol_exporter_queue_size", "service.name"="otelcol-contrib"})', monitor_workspace_id),
        prom_item("collector-failures", "Collector exporter failures", 'sum by (__name__, exporter) ({__name__="otelcol_exporter_send_failed_metric_points", "service.name"="otelcol-contrib"})', monitor_workspace_id, width="100"),
    ]


def workbook_data(service, workspace_id, monitor_workspace_id):
    scope = span_scope(service)
    lscope = log_scope(service)
    items = [
        markdown("title", f"# OpenTelemetry Demo: {service}\n\nNative OTLP service health, capacity, logs, spans, and trace correlation. Metrics come from Azure Managed Prometheus; logs and spans come from Log Analytics."),
        time_parameter(),
    ]
    items += collector_items(monitor_workspace_id) if service == "otel-collector" else standard_span_items(service, workspace_id)
    items += [
        markdown("capacity-heading", "## Capacity and workload"),
        prom_item("cpu", "Container CPU utilization (%)", f'100 * {{__name__="container.cpu.utilization", "service.name"="{service}"}}', monitor_workspace_id),
        prom_item("memory", "Container memory utilization (%)", f'{{__name__="container.memory.percent", "service.name"="{service}"}}', monitor_workspace_id),
        prom_item("focused", FOCUSED_METRICS[service][1], FOCUSED_METRICS[service][0], monitor_workspace_id, width="100"),
        markdown("diagnostics-heading", "## Dependencies, failures, logs, and traces"),
        kql_item("dependencies", "Outbound dependency health", f'OTelSpans\n| where TimeGenerated {{TimeRange}}\n| where ServiceNamespace == "opentelemetry-demo" and ServiceName == "{service}" and Kind == "Client"\n| summarize Calls=count(), Failures=countif(Success == false or StatusCode =~ "Error"), P95Milliseconds=percentile(DurationMs,95) by DependencyType, Target, Name\n| extend ErrorPercent=100.0*todouble(Failures)/Calls\n| order by Calls desc', workspace_id, "table"),
        kql_item("failed-spans", "Recent failing spans", f'OTelSpans\n| where TimeGenerated {{TimeRange}}\n| where {scope}\n| where Success == false or StatusCode =~ "Error"\n| project TimeGenerated, Name, DurationMs, ResultCode, StatusCode, TraceId, SpanId, Attributes\n| order by TimeGenerated desc\n| take 100', workspace_id, "table"),
        kql_item("error-logs", "Error logs over time", f'OTelLogs\n| where TimeGenerated {{TimeRange}}\n| where {lscope}\n| where SeverityNumber >= 17 or SeverityText in~ ("ERROR", "FATAL")\n| summarize Errors=count() by bin(TimeGenerated, 5m), SeverityText\n| order by TimeGenerated asc', workspace_id),
        kql_item("recent-logs", "Recent warning/error logs", f'OTelLogs\n| where TimeGenerated {{TimeRange}}\n| where {lscope}\n| where SeverityNumber >= 13 or SeverityText in~ ("WARN", "WARNING", "ERROR", "FATAL")\n| project TimeGenerated, SeverityText, Body, TraceId, SpanId, Attributes\n| order by TimeGenerated desc\n| take 100', workspace_id, "table"),
        kql_item("trace-summary", "Recent traces touching this service", f'OTelSpans\n| where TimeGenerated {{TimeRange}}\n| where {scope}\n| summarize FirstSeen=min(TimeGenerated), LastSeen=max(TimeGenerated), Spans=count(), Errors=countif(Success == false or StatusCode =~ "Error"), MaxSpanMilliseconds=max(DurationMs), Operations=make_set(Name, 8) by TraceId\n| order by LastSeen desc\n| take 100', workspace_id, "table", "100"),
    ]
    return {"version": "Notebook/1.0", "items": items, "fallbackResourceIds": [workspace_id, monitor_workspace_id]}


def workbook_resource(service, workspace_id, monitor_workspace_id, location):
    data = workbook_data(service, workspace_id, monitor_workspace_id)
    return {
        "location": location,
        "kind": "shared",
        "tags": {"project": "opentelemetry-demo", "managed-by": "deploy-azure-dashboards"},
        "properties": {
            "displayName": f"OpenTelemetry Demo - {service}",
            "serializedData": json.dumps(data, separators=(",", ":")),
            "version": "1.0",
            "sourceId": workspace_id.lower(),
            "category": "workbook",
            "description": f"Native OTLP health and capacity view for {service}.",
        },
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace-id", required=True, help="Log Analytics workspace resource ID")
    parser.add_argument("--monitor-workspace-id", required=True, help="Azure Monitor Workspace resource ID")
    parser.add_argument("--location", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for service in SERVICES:
        workbook_id = str(uuid.uuid5(WORKBOOK_NAMESPACE, service))
        manifest[service] = workbook_id
        path = args.output_dir / f"otel-demo-{service}.json"
        path.write_text(json.dumps(workbook_resource(service, args.workspace_id, args.monitor_workspace_id, args.location), indent=2) + "\n")
    (args.output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()

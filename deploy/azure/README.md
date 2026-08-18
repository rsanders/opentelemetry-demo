# Azure single-VM deployment

This deployment runs the OpenTelemetry Demo's core Docker Compose profile on
one Ubuntu VM. It is intentionally optimized for a disposable demo:

- one VM, no load balancer, autoscaling, or managed observability services;
- an 8-GB burstable SKU by default, the smallest size with practical headroom
  for the core Compose stack;
- a 64-GB standard HDD OS disk;
- a static public IP, with SSH and HTTP restricted to one CIDR; and
- Terraform for Azure resources and Ansible for host configuration and app
  deployment.

Azure resources are named with the `azure-otel-demo` prefix by default.

The default `allowed_cidr` is the `/24` containing the public IP observed when
this deployment was created: `162.200.216.0/24`. Update it if your public
network changes.

## Prerequisites

- Azure CLI authenticated to the target subscription (`az login`)
- Terraform 1.6 or later
- Ansible with the `ansible.posix` collection

Terraform authenticates with the active Azure CLI account; no credentials are
stored in this directory.

## Deploy

```sh
cd deploy/azure
make validate
make up
make outputs
```

`make up` creates the infrastructure, generates an Ansible inventory and SSH
key locally, installs Docker on the VM, syncs this checkout, and starts the
core application. `make outputs` prints the website URL and SSH command.

To change the region, VM SKU, owner tag, compose profile, or network scope,
copy the example variables file:

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

The `core` profile is the lowest-cost option. The `full` profile adds Kafka,
accounting, and fraud detection and needs a larger VM.

## Telemetry

Terraform creates a workspace-based Application Insights resource, a 30-day
Log Analytics workspace, an Azure Monitor Workspace, and a native OTLP Data
Collection Endpoint and Rule. The Compose-network collector forwards all three
signals to a host-network egress collector, which uses the VM's
system-assigned managed identity to send OTLP to Azure Monitor.

### Dashboards and Azure portal locations

Terraform creates the following Azure Monitor Workbooks. They are shared,
Terraform-managed dashboard resources; do not edit them in the portal because
the next Terraform apply will restore their definitions.

| Signal | Dashboard | Azure portal location |
| --- | --- | --- |
| All native signals | [Azure OpenTelemetry Demo - Overview](https://portal.azure.com/#@8d92b17e-a918-47ef-8528-8d048277d9a3/resource/subscriptions/0194be82-31af-4b66-88d1-3f3455eb859a/resourceGroups/azure-otel-demo-rg/providers/Microsoft.Insights/workbooks/8113a38d-eaa3-4727-8e59-207f9d4b1e5f) | [Log Analytics workspace](https://portal.azure.com/#@8d92b17e-a918-47ef-8528-8d048277d9a3/resource/subscriptions/0194be82-31af-4b66-88d1-3f3455eb859a/resourceGroups/azure-otel-demo-rg/providers/Microsoft.OperationalInsights/workspaces/azure-otel-demo-logs/overview) > Workbooks |
| Logs | [Azure OpenTelemetry Demo - Logs](https://portal.azure.com/#@8d92b17e-a918-47ef-8528-8d048277d9a3/resource/subscriptions/0194be82-31af-4b66-88d1-3f3455eb859a/resourceGroups/azure-otel-demo-rg/providers/Microsoft.Insights/workbooks/3af36e72-2f0e-4bd1-bdd5-2cedf66f2790) | [Log Analytics Logs](https://portal.azure.com/#@8d92b17e-a918-47ef-8528-8d048277d9a3/blade/Microsoft_Azure_Monitoring_Logs/LogsBlade/resourceId/%2Fsubscriptions%2F0194be82-31af-4b66-88d1-3f3455eb859a%2FresourceGroups%2Fazure-otel-demo-rg%2Fproviders%2FMicrosoft.OperationalInsights%2Fworkspaces%2Fazure-otel-demo-logs) |
| Traces | [Azure OpenTelemetry Demo - Traces](https://portal.azure.com/#@8d92b17e-a918-47ef-8528-8d048277d9a3/resource/subscriptions/0194be82-31af-4b66-88d1-3f3455eb859a/resourceGroups/azure-otel-demo-rg/providers/Microsoft.Insights/workbooks/8bc9f609-6ef1-4bd0-9fcd-7abcbf7d112b) | [Log Analytics Logs](https://portal.azure.com/#@8d92b17e-a918-47ef-8528-8d048277d9a3/blade/Microsoft_Azure_Monitoring_Logs/LogsBlade/resourceId/%2Fsubscriptions%2F0194be82-31af-4b66-88d1-3f3455eb859a%2FresourceGroups%2Fazure-otel-demo-rg%2Fproviders%2FMicrosoft.OperationalInsights%2Fworkspaces%2Fazure-otel-demo-logs) |
| Metrics | [Azure OpenTelemetry Demo - Metrics](https://portal.azure.com/#@8d92b17e-a918-47ef-8528-8d048277d9a3/resource/subscriptions/0194be82-31af-4b66-88d1-3f3455eb859a/resourceGroups/azure-otel-demo-rg/providers/Microsoft.Insights/workbooks/efa668f7-ddc2-458c-bf26-46bfc75c9a91) | [Azure Monitor Workspace](https://portal.azure.com/#@8d92b17e-a918-47ef-8528-8d048277d9a3/resource/subscriptions/0194be82-31af-4b66-88d1-3f3455eb859a/resourceGroups/azure-otel-demo-rg/providers/Microsoft.Monitor/accounts/azure-otel-demo-metrics/overview) > Prometheus explorer |

Those workbooks are cross-service signal explorers. The separately generated
[per-service workbooks](dashboards/README.md) combine native KQL and PromQL into
health and capacity views for each of the 20 Compose services. They replace the
legacy Portal dashboards whose `AppRequests` and `AppMetrics` queries stopped
receiving data when ingestion moved to native OTLP.

The native stores, rather than legacy `App*` tables, are:

- **Logs:** `OTelLogs` in `azure-otel-demo-logs`.
- **Traces:** `OTelSpans` (spans) and `OTelEvents` (span events) in
  `azure-otel-demo-logs`. Traces are reconstructed by grouping spans on
  `TraceId`; the deployed environment does not currently populate a separate
  `OTelTraces` table.
- **Resource records:** `OTelResources` in `azure-otel-demo-logs`. A resource
  record represents the OpenTelemetry resource identity shared by telemetry,
  such as `service.name`, `service.namespace`, host, process, and SDK
  attributes. `OTelSpans.ResourceAttributesId` can reference `OTelResources.Id`;
  the complete resource attribute bag is also exposed as
  `OTelSpans.ResourceAttributes`.
- **Metrics:** Prometheus time series in the `azure-otel-demo-metrics` Azure
  Monitor Workspace.

### Query native logs and traces

In the Log Analytics **Logs** blade, select the
`azure-otel-demo-logs` workspace and run KQL:

```kusto
// Recent application logs and their OpenTelemetry correlation IDs.
OTelLogs
| where TimeGenerated > ago(1h)
| where ServiceNamespace == "opentelemetry-demo"
| project TimeGenerated, ServiceName, SeverityText, Body, TraceId, SpanId,
          Attributes, ResourceAttributes
| order by TimeGenerated desc
```

```kusto
// Recent spans, including duration, parent relationship, status, and attributes.
OTelSpans
| where TimeGenerated > ago(1h)
| where ServiceNamespace == "opentelemetry-demo"
| project TimeGenerated, ServiceName, Name, Kind, DurationMs, StatusCode,
          TraceId, SpanId, ParentSpanId, Attributes, ResourceAttributes
| order by TimeGenerated desc
```

```kusto
// Inspect resource identities and attributes shared by telemetry.
OTelResources
| where TimeGenerated > ago(1h)
| project TimeGenerated, Id, ServiceName, ServiceNamespace, Attributes
| order by TimeGenerated desc
```

For native log and trace records, resource attributes such as
`service.name` and `service.namespace` are promoted to `ServiceName` and
`ServiceNamespace`; the original resource map is retained in
`ResourceAttributes`. Log and span attributes are retained in the `Attributes`
dynamic JSON column. Trace context is retained as `TraceId`, `SpanId`, and
`ParentSpanId`, allowing joins between the signals.

### Query native metrics and labels

Open the [Azure Monitor Workspace](https://portal.azure.com/#@8d92b17e-a918-47ef-8528-8d048277d9a3/resource/subscriptions/0194be82-31af-4b66-88d1-3f3455eb859a/resourceGroups/azure-otel-demo-rg/providers/Microsoft.Monitor/accounts/azure-otel-demo-metrics/overview),
select **Prometheus explorer**, and run PromQL:

```promql
{__name__="k6.http_reqs", "service.name"="load-generator"}
```

```promql
sum by ("service.name", status) (
  {__name__="k6.http_reqs", "service.namespace"="opentelemetry-demo"}
)
```

The metric name is preserved (`k6.http_reqs`), and OpenTelemetry resource and
point attributes become Prometheus labels. The verified series includes
`service.name`, `service.namespace`, `deployment.environment.name`, `method`,
`status`, `scenario`, and `host.name`. Dotted label names must be quoted in
PromQL, as in `"service.name"`.

### Command-line verification

These commands use the signed-in Azure CLI identity and were used to verify
the deployment. Replace the time window as needed.

```sh
# Native logs, spans, and resource records by table.
az monitor log-analytics query \
  --workspace 94d08632-2ad0-441b-9678-9ed8ea3b5d49 \
  --analytics-query \
    'union OTelLogs, OTelSpans, OTelResources
     | where TimeGenerated > ago(1h)
     | summarize Records=count(), Latest=max(TimeGenerated) by Type
     | order by Records desc' \
  --output table
```

```sh
# A sample of correlated native log records.
az monitor log-analytics query \
  --workspace 94d08632-2ad0-441b-9678-9ed8ea3b5d49 \
  --analytics-query \
    'OTelLogs
     | where TimeGenerated > ago(1h)
     | project TimeGenerated, ServiceName, Body, TraceId, SpanId
     | take 10' \
  --output table
```

```sh
# Native metric series and their OpenTelemetry-derived labels.
TOKEN="$(az account get-access-token \
  --resource https://prometheus.monitor.azure.com \
  --query accessToken --output tsv)"
curl --fail --silent --show-error --get \
  --data-urlencode 'query={__name__="k6.http_reqs"}' \
  -H "Authorization: Bearer $TOKEN" \
  'https://azure-otel-demo-metrics-hydkekhjeqb2gzb0.westus2.prometheus.monitor.azure.com/api/v1/query'
```

## Operations

```sh
make update                 # re-sync and restart the demo
make status                 # list container status
make logs SERVICE=frontend-proxy
make shell                  # open a shell on the VM host
make container-shell        # open a shell in frontend-proxy
make container-shell SERVICE=cart
make down                   # destroy all Azure resources and stop billing
```

The public IP, VM, and disk are billable while they exist. Run `make down`
when the demo is no longer needed.

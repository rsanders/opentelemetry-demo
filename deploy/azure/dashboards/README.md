# Per-service native OpenTelemetry workbooks

The four Terraform-managed workbooks are cross-service signal explorers. These
20 independently managed workbooks provide service-level health, capacity,
dependency, log, span, and trace-correlation views.

The native ingestion path splits telemetry by signal:

- spans and logs are queried with KQL from `OTelSpans` and `OTelLogs` in Log Analytics;
- metrics are queried with PromQL from the Azure Monitor Workspace; and
- Application Insights remains the resource reference on the Data Collection Rule,
  but the legacy `AppRequests`, `AppDependencies`, `AppMetrics`, and `AppTraces`
  tables are not the data source for these workbooks.

Generate portable workbook request bodies using the deployed resource IDs:

```sh
python3 deploy/azure/dashboards/generate_dashboards.py \
  --workspace-id /subscriptions/SUBSCRIPTION/resourceGroups/GROUP/providers/Microsoft.OperationalInsights/workspaces/WORKSPACE \
  --monitor-workspace-id /subscriptions/SUBSCRIPTION/resourceGroups/GROUP/providers/Microsoft.Monitor/accounts/MONITOR_WORKSPACE \
  --location westus2 \
  --output-dir deploy/azure/dashboards/generated
```

Inspect the intended writes, then deploy only the workbook resources. This does
not invoke Terraform or redeploy the application:

```sh
python3 deploy/azure/dashboards/deploy_dashboards.py \
  --resource-group azure-otel-demo-rg \
  --input-dir deploy/azure/dashboards/generated \
  --dry-run

python3 deploy/azure/dashboards/deploy_dashboards.py \
  --resource-group azure-otel-demo-rg \
  --input-dir deploy/azure/dashboards/generated
```

Workbook IDs are UUIDv5 values derived from the service name, so deployment is
idempotent. The Terraform-managed signal workbooks are deliberately not changed.

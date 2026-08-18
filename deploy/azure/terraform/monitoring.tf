resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.project_name}-logs"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.tags
}

resource "azurerm_application_insights" "this" {
  name                         = "${var.project_name}-insights"
  location                     = azurerm_resource_group.this.location
  resource_group_name          = azurerm_resource_group.this.name
  application_type             = "web"
  workspace_id                 = azurerm_log_analytics_workspace.this.id
  local_authentication_enabled = false
  internet_ingestion_enabled   = true
  internet_query_enabled       = true
  retention_in_days            = 30

  tags = local.tags
}

resource "azurerm_monitor_workspace" "this" {
  name                = "${var.project_name}-metrics"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  tags = local.tags
}

resource "azurerm_monitor_data_collection_endpoint" "otlp" {
  name                = "${var.project_name}-otlp-dce"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  description         = "Native OTLP ingestion endpoint for the OpenTelemetry demo."

  tags = local.tags
}

resource "azurerm_resource_group_template_deployment" "otlp_dcr" {
  name                = "${var.project_name}-otlp-dcr-deployment"
  resource_group_name = azurerm_resource_group.this.name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    resources = [{
      type       = "Microsoft.Insights/dataCollectionRules"
      apiVersion = "2024-03-11"
      name       = "${var.project_name}-otlp-dcr"
      location   = azurerm_resource_group.this.location
      properties = {
        dataCollectionEndpointId = azurerm_monitor_data_collection_endpoint.otlp.id
        references = {
          applicationInsights = [{
            resourceId = azurerm_application_insights.this.id
            name       = "applicationInsightsResource"
          }]
        }
        dataSources = {
          otelMetrics = [{
            streams                      = ["Custom-Metrics-Otel"]
            enrichWithResourceAttributes = ["*"]
            enrichWithReference          = "applicationInsightsResource"
            name                         = "otelMetricsDataSource"
          }]
          otelLogs = [{
            streams                        = ["Microsoft-OTel-Logs"]
            enrichWithResourceAttributes   = ["*"]
            enrichWithReference            = "applicationInsightsResource"
            replaceResourceIdWithReference = true
            name                           = "otelLogsDataSource"
          }]
          otelTraces = [{
            streams                        = ["Microsoft-OTel-Traces-Spans", "Microsoft-OTel-Traces-Events", "Microsoft-OTel-Traces-Resources"]
            enrichWithResourceAttributes   = ["*"]
            enrichWithReference            = "applicationInsightsResource"
            replaceResourceIdWithReference = true
            name                           = "otelTracesDataSource"
          }]
        }
        directDataSources = {
          otelMetrics = [{
            streams                      = ["Custom-Metrics-Otel"]
            enrichWithResourceAttributes = ["*"]
            enrichWithReference          = "applicationInsightsResource"
            name                         = "otelMetricsDataSourceDirect"
          }]
          otelLogs = [{
            streams                        = ["Microsoft-OTel-Logs"]
            enrichWithResourceAttributes   = ["*"]
            enrichWithReference            = "applicationInsightsResource"
            replaceResourceIdWithReference = true
            name                           = "otelLogsDataSourceDirect"
          }]
          otelTraces = [{
            streams                        = ["Microsoft-OTel-Traces-Spans", "Microsoft-OTel-Traces-Events", "Microsoft-OTel-Traces-Resources"]
            enrichWithResourceAttributes   = ["*"]
            enrichWithReference            = "applicationInsightsResource"
            replaceResourceIdWithReference = true
            name                           = "otelTracesDataSourceDirect"
          }]
        }
        destinations = {
          monitoringAccounts = [{
            accountResourceId = azurerm_monitor_workspace.this.id
            name              = "azureMonitorWorkspace"
          }]
          logAnalytics = [{
            workspaceResourceId = azurerm_log_analytics_workspace.this.id
            name                = "logAnalyticsWorkspace"
          }]
        }
        dataFlows = [
          {
            streams      = ["Custom-Metrics-Otel"]
            destinations = ["azureMonitorWorkspace"]
          },
          {
            streams      = ["Microsoft-OTel-Logs", "Microsoft-OTel-Traces-Spans", "Microsoft-OTel-Traces-Events", "Microsoft-OTel-Traces-Resources"]
            destinations = ["logAnalyticsWorkspace"]
          }
        ]
      }
    }]
    outputs = {
      immutableId = {
        type  = "String"
        value = "[reference(resourceId('Microsoft.Insights/dataCollectionRules', '${var.project_name}-otlp-dcr'), '2024-03-11', 'full').properties.immutableId]"
      }
    }
  })
}

resource "azurerm_role_assignment" "otlp_dcr_publisher" {
  scope                = "${azurerm_resource_group.this.id}/providers/Microsoft.Insights/dataCollectionRules/${var.project_name}-otlp-dcr"
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id

  depends_on = [azurerm_resource_group_template_deployment.otlp_dcr]
}

resource "azurerm_application_insights_workbook" "overview" {
  name                = "8113a38d-eaa3-4727-8e59-207f9d4b1e5f"
  display_name        = "Azure OpenTelemetry Demo - Overview"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  source_id           = lower(azurerm_log_analytics_workspace.this.id)
  category            = "workbook"
  description         = "Native OTLP telemetry overview for the OpenTelemetry Demo."
  tags                = local.tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        name = "overview-title"
        content = {
          json = "# Azure OpenTelemetry Demo\n\nThis workbook shows telemetry received through Azure's native OTLP ingestion path."
        }
      },
      {
        type = 3
        name = "signal-volume"
        content = {
          version       = "KqlItem/1.0"
          query         = "union OTelLogs, OTelSpans, OTelResources\n| where TimeGenerated > ago(1h)\n| summarize Records = count(), Latest = max(TimeGenerated) by Type\n| order by Records desc"
          size          = 0
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "table"
        }
      }
    ]
  })
}

resource "azurerm_application_insights_workbook" "logs" {
  name                = "3af36e72-2f0e-4bd1-bdd5-2cedf66f2790"
  display_name        = "Azure OpenTelemetry Demo - Logs"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  source_id           = lower(azurerm_log_analytics_workspace.this.id)
  category            = "workbook"
  description         = "Native OTLP logs for the OpenTelemetry Demo."
  tags                = local.tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        name = "logs-title"
        content = {
          json = "# Native OTLP logs\n\nAll records are from the `OTelLogs` table in the linked Log Analytics workspace."
        }
      },
      {
        type = 3
        name = "recent-logs"
        content = {
          version       = "KqlItem/1.0"
          query         = "OTelLogs\n| where TimeGenerated > ago(1h)\n| where ServiceNamespace == \"opentelemetry-demo\"\n| project TimeGenerated, ServiceName, SeverityText, Body, TraceId, SpanId, Attributes, ResourceAttributes\n| order by TimeGenerated desc"
          size          = 0
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "table"
        }
      }
    ]
  })
}

resource "azurerm_application_insights_workbook" "traces" {
  name                = "8bc9f609-6ef1-4bd0-9fcd-7abcbf7d112b"
  display_name        = "Azure OpenTelemetry Demo - Traces"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  source_id           = lower(azurerm_log_analytics_workspace.this.id)
  category            = "workbook"
  description         = "Native OTLP spans for the OpenTelemetry Demo."
  tags                = local.tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        name = "traces-title"
        content = {
          json = "# Native OTLP traces\n\nAll spans are from the `OTelSpans` table in the linked Log Analytics workspace."
        }
      },
      {
        type = 3
        name = "recent-spans"
        content = {
          version       = "KqlItem/1.0"
          query         = "OTelSpans\n| where TimeGenerated > ago(1h)\n| where ServiceNamespace == \"opentelemetry-demo\"\n| project TimeGenerated, ServiceName, Name, Kind, DurationMs, StatusCode, TraceId, SpanId, ParentSpanId, Attributes\n| order by TimeGenerated desc"
          size          = 0
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "table"
        }
      }
    ]
  })
}

resource "azurerm_application_insights_workbook" "metrics" {
  name                = "efa668f7-ddc2-458c-bf26-46bfc75c9a91"
  display_name        = "Azure OpenTelemetry Demo - Metrics"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  source_id           = lower(azurerm_monitor_workspace.this.id)
  category            = "workbook"
  description         = "Native OTLP metrics query guide for the OpenTelemetry Demo."
  tags                = local.tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [{
      type = 1
      name = "metrics-guide"
      content = {
        json = "# Native OTLP metrics\n\nMetrics are stored in the Azure Monitor Workspace as Prometheus series. Open the linked Azure Monitor Workspace and select **Prometheus explorer**.\n\nExample query:\n\n```promql\n{__name__=\"k6.http_reqs\", \"service.name\"=\"load-generator\"}\n```\n\nThe metric name and each OpenTelemetry attribute are retained as Prometheus labels. For example, `service.name`, `service.namespace`, `method`, `status`, and `deployment.environment.name` are filterable labels on `k6.http_reqs`."
      }
    }]
  })
}

# Metrics Collection

This document explains **how** every metric in the OpenTelemetry Demo gets
from a service into the `otel-collector`, and **what** is available once it's
there. It complements `telemetry-schema/` (the source of truth for the
demo's *custom* business attributes/metrics) by also covering the
standard/semconv metrics, infrastructure metrics, and collector-derived
metrics that aren't declared in the schema because they aren't demo-specific.

## Collection mechanisms

Every metric in this stack reaches the collector one of five ways:

| Mechanism | How it works | Where it's configured |
| --- | --- | --- |
| **Direct OTLP export** | The service's own SDK/agent pushes metrics straight to the collector's OTLP receiver (`4317` grpc / `4318` http). This is the preferred path — it's how most business and runtime metrics arrive. | Each service's `OTEL_EXPORTER_OTLP_ENDPOINT` env var; receiver config in `src/otel-collector/otelcol-config.yml`'s `otlp` receiver. |
| **Prometheus scrape** | The collector polls a `/metrics`-style HTTP endpoint the service (or proxy) already exposes in Prometheus text format, instead of the service pushing anything itself. Used when a component only speaks Prometheus natively. | `prometheus/*` receivers in `otelcol-config.yml`. |
| **Collector-native receiver** | A purpose-built collector receiver polls a non-Prometheus, non-OTLP protocol directly (Docker API, `/proc`, nginx's `stub_status`, Redis's `INFO` command, Postgres's catalog views, the Kafka wire protocol). | `docker_stats`, `host_metrics`, `nginx`, `redis`, `postgresql`, `kafkametrics`, `http_check/*` receivers in `otelcol-config.yml`. |
| **Log-derived** | The collector counts matching OTLP log records into a metric. Used where a component emits rich structured logs but no metrics of its own. | `count/frontend_proxy_http` connector in `otelcol-config.yml`. |
| **Trace-derived** | The collector aggregates every span that flows through the traces pipeline into call-count and duration metrics, regardless of whether the emitting service produces metrics itself. This is a safety net that covers *every* instrumented service, even ones with no metrics story of their own. | `span_metrics` connector in `otelcol-config.yml`. |

Every Prometheus-scraped target also gets a synthetic `up` gauge (1 =
last scrape succeeded, 0 = failed) — omitted from the tables below since
it's identical in shape for every scrape target.

Metric types: **Counter** (monotonic sum), **Histogram**, **Gauge**.

---

## Whole-stack metrics

These aren't tied to one service — they characterize the platform or every
service at once.

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `traces.span.metrics.calls` | Counter | Traces (span_metrics connector) | Span count per unique `(service.name, span.name, span.kind, status.code)` combination — i.e. a request-rate metric for *every* operation in *every* instrumented service, derived purely from spans. |
| `traces.span.metrics.duration` | Histogram | Traces (span_metrics connector) | Span duration, same dimensions as above — a latency metric for every operation, again derived from spans alone, so it exists even for services with no native metrics (e.g. quote, checkout, image-provider). |
| `container.cpu.utilization`, `container.cpu.usage.total` | Gauge / Counter | Collector-native (`docker_stats`) | Per-container CPU usage, for every container Docker is running — service-agnostic infrastructure visibility. |
| `container.memory.usage.total`, `container.memory.percent` | Counter / Gauge | Collector-native (`docker_stats`) | Per-container memory usage/limit. |
| `container.network.io.usage.rx_bytes` / `tx_bytes` | Counter | Collector-native (`docker_stats`) | Per-container network I/O. |
| `container.blockio.io_service_bytes_recursive` | Counter | Collector-native (`docker_stats`) | Per-container disk I/O. |
| `system.cpu.utilization`, `system.cpu.logical.count` | Gauge | Collector-native (`host_metrics`) | Host-level CPU utilization and core count (the Docker/VM host, not a container). |
| `system.memory.utilization`, `system.memory.limit` | Gauge | Collector-native (`host_metrics`) | Host-level memory. |
| `system.disk.io`, `system.disk.operations` | Counter | Collector-native (`host_metrics`) | Host-level disk throughput/IOPS. |
| `system.network.io`, `system.network.errors` | Counter | Collector-native (`host_metrics`) | Host-level network throughput/errors. |
| `system.paging.usage` | Gauge | Collector-native (`host_metrics`) | Host swap usage. |
| `system.uptime` | Gauge | Collector-native (`host_metrics`) | Host uptime. |
| `process.cpu.time`, `process.memory.usage` | Counter / Gauge | Collector-native (`host_metrics`, `process` scraper) | Per-OS-process CPU/memory, keyed by process name (covers every container's main process visible from the host). |
| `otel.sdk.*` (queue size, export counts, etc.) | Counter / Histogram / Gauge | Direct OTLP (SDK self-observability) | Opt-in OTel SDK self-monitoring metrics, enabled per-service via `OTEL_EXPERIMENTAL_SDK_TELEMETRY_VERSION=latest` (set on `ad` and several others) — feeds the "self-observability" Grafana dashboard rather than describing the app itself. |

---

## Frontend & edge

### frontend (Next.js)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `http.server.request.duration` | Histogram | Direct OTLP (`@opentelemetry/instrumentation-http`, via `NodeSDK`) | Duration of every HTTP request the Next.js server handles, with `http.route`, `http.request.method`, `http.response.status_code` attributes. `http.route` is set explicitly per API handler in `InstrumentationMiddleware.ts` (e.g. `/api/products/{productId}`) so dynamic segments don't blow up cardinality — see the frontend-proxy HTTP metrics work earlier in this change set. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Same as whole-stack, scoped to `service.name="frontend"` — covers page-render (SSR) spans that aren't behind `InstrumentationMiddleware`. |
| `process.runtime.node.*` (if enabled by the bundled auto-instrumentations) | Various | Direct OTLP | Node.js event loop lag, heap usage, GC pauses — present if the resolved `@opentelemetry/auto-instrumentations-node` version bundles runtime metrics; not independently verified this session. |

### frontend-proxy (Envoy)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `envoy_cluster_external_upstream_rq{envoy_response_code, envoy_cluster_name}` | Counter | Prometheus scrape (`prometheus/envoy`, new) | Requests to each upstream cluster (frontend, image-provider, flagd-ui, telemetry-docs, chatbot, profiles, …) by exact response code — this is Envoy's own view of "status code by destination," independent of the log-derived metric below. |
| `envoy_http_downstream_rq_xx{...}` (2xx/3xx/4xx/5xx families) | Counter | Prometheus scrape (`prometheus/envoy`, new) | Downstream (browser-facing) request counts by response-code class, per listener. |
| `envoy_cluster_upstream_rq_time` | Histogram | Prometheus scrape (`prometheus/envoy`, new) | Upstream request latency per cluster. |
| `envoy_cluster_upstream_cx_active`, `envoy_listener_downstream_cx_active` | Gauge | Prometheus scrape (`prometheus/envoy`, new) | Active connection counts, upstream and downstream. |
| `envoy_server_*`, `envoy_cluster_manager_*` | Various | Prometheus scrape (`prometheus/envoy`, new) | Envoy's own process/server health stats (uptime, memory, hot restart generation, cluster warm-up state). Scraped with `usedonly=true` so never-incremented stats are skipped — Envoy's admin interface exposes several hundred series in total; the ones above are the operationally relevant subset. |
| `http.server.request.count` | Counter | Log-derived (`count/frontend_proxy_http`, new) | Total requests, grouped by `http.route`, `http.request.method`, `http.response.status_code` — this is the "status code by path" / "total requests by path" view, built from Envoy's OTLP access log (Envoy's own OTel tracer doesn't yet expose route-level stats natively, so this fills the gap the Prometheus scrape above can't). |
| `httpcheck.duration`, `httpcheck.status`, `httpcheck.error` | Gauge / Sum | Collector-native (`http_check/frontend-proxy`) | Simple external liveness probe — is frontend-proxy's root URL reachable and returning a healthy status. Independent of the two sources above; this one works even if Envoy's own telemetry pipeline is broken. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Envoy also emits an OTel span per request (`spawn_upstream_span: true`), so it gets whole-stack span-derived coverage too, at the (coarser) span-name granularity rather than by route. |

---

## Core checkout path

### cart (.NET / ASP.NET Core, gRPC)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `demo.cart.add_item.latency` | Histogram | Direct OTLP (custom) | Latency of the add-item operation, custom bucket boundaries 5ms–10s. |
| `demo.cart.get_cart.latency` | Histogram | Direct OTLP (custom) | Latency of cart retrieval. |
| `http.server.request.duration` | Histogram | Direct OTLP (`AddAspNetCoreInstrumentation`, `.WithMetrics()`) | Kestrel/ASP.NET Core request duration — since cart serves gRPC only, `http.route` reflects the gRPC method path, not a REST path. |
| `process.runtime.dotnet.*` (GC, thread pool, exceptions) | Various | Direct OTLP (`AddRuntimeInstrumentation`) | .NET runtime health. |
| `process.cpu.*`, `process.memory.*` | Various | Direct OTLP (`AddProcessInstrumentation`) | Process-level resource usage, OTel semconv form (distinct from the collector's own host-side `process.*` scrape). |

### checkout (Go, gRPC)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `rpc.server.duration` | Histogram | Direct OTLP (`otelgrpc.NewServerHandler`) | Duration of inbound gRPC calls (PlaceOrder, etc.), by gRPC method/status. |
| `rpc.client.duration` | Histogram | Direct OTLP (`otelgrpc.NewClientHandler`) | Duration of checkout's outbound gRPC calls to cart, currency, email, payment, product-catalog, shipping — this is where cross-service latency for the checkout flow shows up. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Backstop coverage; checkout has no custom business metric registered in `telemetry-schema/`. |

### currency (C++, gRPC)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `demo.exchange.conversions` | Counter | Direct OTLP (custom) | Currency conversions performed, labeled by target currency (`demo.exchange.to`). |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Backstop coverage for gRPC call volume/latency. |

### payment (Node.js, gRPC)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `demo.payment.transactions` | Counter | Direct OTLP (custom) | Payment transactions processed, labeled by `demo.payment.currency`. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Backstop coverage; payment is gRPC-only so no `http.server.*` metrics apply. |

### product-catalog (Go, gRPC)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `rpc.server.duration` | Histogram | Direct OTLP (`otelgrpc.NewServerHandler`) | Inbound gRPC call duration (GetProduct, ListProducts, …). |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Backstop coverage; no custom business metric registered. |

### shipping (Rust / actix-web)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `demo.shipping.items_shipped` | Counter | Direct OTLP (custom) | Number of items shipped. |
| `http.server.request.duration` (or equivalent actix-web metric) | Histogram | Direct OTLP (`opentelemetry-instrumentation-actix-web`'s `RequestMetrics` middleware) | Full HTTP request metrics — route, method, status — since shipping runs a real REST server (`/quote`, `/ship_order`, `/health`). This is the most complete native metrics story of any backend service in the demo; the frontend fix earlier in this change set brought `frontend` up to the same standard. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Backstop coverage. |

---

## Catalog & discovery

### ad (Java)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `demo.ad.requests` | Counter | Direct OTLP (custom, Java agent) | Ad requests, labeled by `demo.ad.request_type` / `demo.ad.response_type`. |
| `demo_ad_served_total` | Counter | Prometheus scrape (`prometheus/ad`) | Same underlying event, but recorded via the raw `io.prometheus.metrics` client library (not the OTel SDK) and scraped — an intentional, documented example of bridging pre-existing Prometheus instrumentation into an OTel pipeline, kept alongside the OTLP-native counter above rather than replacing it. Labeled by `category`. |
| `process.runtime.jvm.*` (GC, memory pools, threads, classes loaded) | Various | Direct OTLP (Java agent, automatic) | Standard JVM telemetry, emitted by every Java-agent-instrumented service (ad, kafka, fraud-detection) without any app code. |
| `rpc.server.duration` | Histogram | Direct OTLP (Java agent, gRPC auto-instrumentation) | Inbound gRPC call duration. |

### quote (PHP / Slim on ReactPHP)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Quote has an OTel meter provider configured (`OTEL_PHP_INTERNAL_METRICS_ENABLED=true`) but the Slim auto-instrumentation is trace-only, and no custom business metric is registered — span-derived metrics are the only confirmed signal today. Flagged as a candidate for direct HTTP metrics in a future pass (see the earlier discussion of services needing bespoke work). |

### recommendation (Python, gRPC)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `demo.recommendation.requests` | Counter | Direct OTLP (custom) | Recommendation requests, labeled by `recommendation.type`. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Backstop coverage; recommendation is gRPC-only with no framework-level metrics instrumentation wired up. |

---

## Notification

### email (Ruby / Sinatra)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `demo.notification.confirmations` | Counter | Direct OTLP (custom) | Confirmation emails sent. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Backstop coverage; the Sinatra auto-instrumentation is trace-only, so this is the only source of request-level metrics beyond the custom counter. |

---

## Async / Kafka consumers *(compose.full.yaml only)*

### kafka

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `process.runtime.jvm.*`, broker JMX metrics | Various | Direct OTLP (Java agent, `-Dotel.jmx.target.system=kafka-broker`) | Kafka broker internals via JMX Insight — the primary metrics source for Kafka, fully OTLP-native (no Prometheus involved). |
| `kafka.brokers`, `kafka.topic.partitions` | Sum | Collector-native (`kafkametrics`) | Cluster/topic-level metadata via the Kafka wire protocol directly (complementary to the JMX metrics — broker count and partition topology rather than broker internals). |
| `kafka.consumer_group.lag`, `kafka.consumer_group.lag_sum` | Gauge | Collector-native (`kafkametrics`) | Consumer lag for the accounting/fraud-detection consumer groups — the number to watch if either falls behind. |
| `kafka.partition.current_offset`, `kafka.partition.oldest_offset` | Gauge | Collector-native (`kafkametrics`) | Partition offset bounds. |

### accounting (.NET, Kafka consumer)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `process.runtime.dotnet.*` | Various | Direct OTLP (`OpenTelemetry.AutoInstrumentation`) | .NET runtime health; no HTTP or gRPC server, so no request-shaped metrics apply. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Backstop coverage for Kafka-consume spans, if the consume operation is instrumented for tracing. No custom business metric is registered. |

### fraud-detection (Kotlin, Kafka consumer)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `process.runtime.jvm.*` | Various | Direct OTLP (Java agent, automatic) | JVM health; same mechanism as `ad`. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | Backstop coverage for Kafka-consume spans. No custom business metric is registered. |

---

## Feature flags

### flagd

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `feature_flag_flagd_impression_total` | Counter | Prometheus scrape (`prometheus/flagd`, new) | Evaluations per flag key, labeled by `feature_flag_key`, `feature_flag_reason`, `feature_flag_result_variant` — this is what every flag toggle in the demo (adFailure, cartFailure, kafkaQueueProblems, loadGeneratorTraffic, …) shows up as. |
| `feature_flag_flagd_result_reason_total` | Counter | Prometheus scrape (`prometheus/flagd`, new) | Evaluations per result reason (STATIC, DEFAULT, TARGETING_MATCH, …). |
| `http_server_request_duration_seconds` | Histogram | Prometheus scrape (`prometheus/flagd`, new) | flagd's own inbound HTTP/OFREP request duration — recorded on every flag evaluation regardless of transport. |
| `rpc_server_duration_milliseconds` | Histogram | Prometheus scrape (`prometheus/flagd`, new) | Inbound gRPC sync-service call duration (flagd-ui and other sync clients streaming flag state). |
| `go_goroutines`, `go_memstats_*`, `process_resident_memory_bytes`, … | Gauge / Counter | Prometheus scrape (`prometheus/flagd`, new) | Standard Go runtime/process metrics, included for free on flagd's `/metrics` endpoint. |

flagd is Prometheus-only by default (`--metrics-exporter` defaults to
`prometheus`, and `--otel-collector-uri` isn't set) — everything above
previously existed only on flagd's own `/metrics` endpoint and wasn't
reaching the collector until this change. Confirmed against the live
endpoint (`curl localhost:8014/metrics` after `docker compose up`) rather
than docs alone.

### flagd-ui (Elixir / Phoenix)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | `opentelemetry_phoenix`/`opentelemetry_bandit` are trace-only; Elixir's own `Telemetry.Metrics` (used for the LiveDashboard) isn't wired to the OTLP pipeline, so span-derived metrics are the only signal reaching the collector today. |

---

## Supporting infrastructure

### image-provider (nginx)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `nginx.requests` | Sum | Collector-native (`nginx` receiver, scrapes `stub_status`) | Total requests served. |
| `nginx.connections_accepted` / `_handled` / `_current` | Sum / Sum / Sum | Collector-native (`nginx`) | Connection counts and current state. |
| `traces.span.metrics.calls` / `.duration` | Counter / Histogram | Traces (span_metrics) | `ngx_otel_module` is trace-only; nginx has no per-route concept for a static file server, so route-level detail isn't meaningful here the way it is for frontend-proxy. |

### astronomy-db (PostgreSQL)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `postgresql.blks_hit` / `.blks_read` | Sum | Collector-native (`postgresql`) | Buffer cache hit/miss — the primary "is the DB working set in memory" signal. |
| `postgresql.tup_fetched` / `.tup_inserted` / `.tup_updated` / `.tup_deleted` | Sum | Collector-native (`postgresql`) | Row-level DML activity. |
| `postgresql.deadlocks` | Sum | Collector-native (`postgresql`) | Deadlock count. |
| `postgresql.commits`, `postgresql.rollbacks`, `postgresql.backends`, `postgresql.db_size` | Sum / Sum / Sum / Sum | Collector-native (`postgresql`, default-enabled) | Standard database health metrics enabled without extra config. |

### valkey-cart (Redis-compatible, used by cart)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `redis.clients.connected` | Sum | Collector-native (`redis`) | Active client connections. |
| `redis.commands.processed`, `redis.commands` | Sum / Gauge | Collector-native (`redis`) | Command throughput (total and per-second). |
| `redis.keyspace.hits` / `.misses` | Sum | Collector-native (`redis`) | Cache hit rate for cart lookups. |
| `redis.memory.used`, `redis.memory.fragmentation_ratio` | Gauge | Collector-native (`redis`) | Memory health. |

### telemetry-docs, opamp-server

No native or custom telemetry beyond whole-stack coverage:
`telemetry-docs` is a static mkdocs site served by nginx (no
`ngx_otel_module`, so not even trace-derived metrics), and `opamp-server`
manages the collector over the OpAMP protocol rather than emitting its
own business telemetry. Both still show up in
`docker_stats`/`host_metrics`/`process.*`.

### load-generator (k6 / xk6-otel)

| Metric | Type | Source | Description |
| --- | --- | --- | --- |
| `k6.http_reqs`, `k6.http_req_duration`, `k6.vus`, `k6.iterations`, … | Counter / Histogram / Gauge / Counter | Direct OTLP (`xk6-otel` output plugin) | k6's own client-side load-test metrics — request rate/latency as *generated*, not as received — exported with a `k6.` prefix (`K6_OTEL_METRIC_PREFIX`) to keep them clearly distinct from any server-side metric of the same shape. This describes the load generator itself, not the services it's driving traffic against. |

---

## Optional agent add-ons *(compose.agent.yaml only)*

`chatbot`, `mcp`, and `agent` are an opt-in overlay, not part of the
core/full/observability profiles used elsewhere in this document.
`chatbot` (Python/Gradio) currently has no `MeterProvider` configured at
all — no metrics of any kind, not even span-derived beyond whatever
traces its `RequestsInstrumentor`/`HTTPXClientInstrumentor` produce for
outbound calls. `mcp` and `agent` weren't in scope for this pass; treat
their metrics coverage as unverified.

---

## Adding a new metric

- **Custom/business metric**: define it in
  `telemetry-schema/metrics/<service>.yaml` first (per `AGENTS.md`), then
  instrument the code. Reuse an existing `telemetry-schema/attributes/`
  entry before inventing a new one.
- **New scrape target**: add a `prometheus/<name>` receiver to
  `otelcol-config.yml`, wire its host:port through a composed `*_ADDR`
  env var in `.env` (see `AD_PROMETHEUS_ADDR`, `ENVOY_ADMIN_ADDR`,
  `FLAGD_MANAGEMENT_ADDR` for the pattern) rather than hardcoding a
  hostname, add it to the `metrics` pipeline's `receivers` list in
  **both** `otelcol-config.yml` and `otelcol-config-full.yml` (config
  layers replace arrays, not merge them), and mirror the receiver into
  `deploy/aws-ecs/cdk/files/otelcol-config-extras-aws.yml`'s metrics
  `receivers` list with a Cloud-Map-qualified `_ADDR` value set in
  `deploy/aws-ecs/cdk/lib/services.ts` — ECS has no bare-hostname DNS
  resolution the way Compose and the EC2 deploy do.

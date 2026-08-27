# Load Generator

The load generator creates simulated traffic to the demo using
[k6](https://k6.io/).

## Modifying the Load Generator

The load test script lives at [`script.js`](./script.js). See the [k6
documentation](https://grafana.com/docs/k6/latest/) for more on writing k6
scripts.

Tracing and log correlation are provided by a custom k6 extension,
[`xk6-otel`](./xk6-otel), which exposes a `Tracer` to the script (imported as
`k6/x/otel`) for creating OTel spans and injecting `traceparent` headers into
outgoing HTTP requests.

The extension also emits Go runtime metrics (memory, GC, goroutines) via the
OTel contrib `runtime` instrumentation. These are separate from k6's own
built-in test metrics, which are exported via the `--out opentelemetry` output
enabled in [`entrypoint.sh`](./entrypoint.sh)'s `k6 run` invocation; the OTLP
endpoint and protocol for that output are configured via the `K6_OTEL_*` env
vars in `compose.yaml`.

Set `K6_OTEL_TRACES_ENABLED=false` to keep the extension's OTel metrics and
logs while using a no-op tracer that does not send load-generator spans to the
collector. The AWS, AWS ECS, and Azure deployment configurations set this
value and `K6_LOG_LEVEL=warn` by default.

## Traffic mix

Each `httpScenario` iteration picks one task at random, weighted so browsing
dominates over checkout:

| Task                  | Weight |
| --------------------- | -----: |
| `index`               |      1 |
| `browseProduct`       |     10 |
| `getRecommendations`  |      3 |
| `getAds`              |      3 |
| `viewCart`            |      3 |
| `addToCart`           |      2 |
| `checkout`            |      1 |
| `checkoutMulti`       |      1 |
| `floodHome`           |      5 |

## Controlling traffic and concurrency via feature flags

* `loadGeneratorFloodHomepage` - sends 100 additional homepage requests when
  turned on. It is off by default.
* `loadGeneratorTraffic` - pauses all synthetic traffic (both scenarios) when
  turned off, checked every iteration with no restart required.
* `loadGeneratorVUs` - sets the number of concurrent virtual users the HTTP
  scenario runs. k6 v2's `constant-vus` executor can't resize its VU pool at
  runtime - it dropped the externally-controlled executor, and its REST API
  now rejects live VU changes outright - so
  [`entrypoint.sh`](./entrypoint.sh) polls flagd and restarts k6 with the new
  VU count only when this flag's value actually changes, rather than on a
  fixed timer.
`entrypoint.sh` passes the VU count to k6 through the `LOAD_GENERATOR_VUS`
env var, which `script.js` reads directly via `__ENV` to set the HTTP
scenario's `vus`. It is deliberately not named `K6_VUS`: a `K6_VUS` env var
(or `--vus` flag) makes k6 discard the script's `scenarios` config entirely in
favor of a single implicit scenario, the same way `K6_DURATION`/
`K6_ITERATIONS`/`K6_STAGES` do - so none of those reserved names should ever
be set as a container env var here.

The browser scenario runs a single headless browser session alongside the HTTP
traffic, so it always runs one browser VU. It is opt-in via `K6_BROWSER_ENABLED`
(default off), since headless Chromium requires a relaxed pod security context
that most Kubernetes clusters don't grant by default. When enabled, Chromium's
executable path and launch args come from the `K6_BROWSER_EXECUTABLE_PATH` and
`K6_BROWSER_ARGS` env vars (comma-separated, no `--` prefix) rather than the
scenario's own `browser` options field, which k6 ignores for these.

## Agent layer traffic

When the `agent`/`mcp`/`chatbot` GenAI layer (`compose.agent.yaml`) is present
alongside the load generator, three extra scenarios exercise it directly,
each paced with k6's `constant-arrival-rate` executor so the request rate
stays fixed regardless of how long an individual LLM-backed call takes:

| Scenario   | Exec function    | Target                                          | Rate env var        |
| ---------- | ---------------- | ------------------------------------------------ | -------------------- |
| `agent`    | `agentScenario`  | `agent`'s `/prompt` API directly                  | `AGENT_TARGET_RPM`   |
| `mcp`      | `mcpScenario`    | `mcp`'s MCP streamable-HTTP endpoint directly     | `MCP_TARGET_RPM`     |
| `chatbot`  | `chatbotScenario`| the chatbot's Gradio UI, via a headless browser   | `CHATBOT_TARGET_RPM` |

All three default to 5 iterations/minute and are off unless
`K6_AGENT_LAYER_ENABLED=true` is set - `compose.agent.yaml` sets it on the
`load-generator` service so this only activates alongside the GenAI layer
itself, never in a plain `core`/`full` deploy. `agent` and `chatbot` each
make a real LLM call per iteration, so keep the rate env vars low to control
cost; `mcp`'s `list_products` tool call doesn't touch the LLM at all.

`agent` and `mcp` have no route through `frontend-proxy` (only `chatbot`
does, at `/chatbot/`), so `script.js` reaches them directly by their
in-network service names/ports, the same way it already does for `flagd`.

`chatbotScenario` drives the chatbot's actual Gradio UI - filling its
textbox and pressing Enter - rather than calling an internal Gradio API
endpoint, since Gradio doesn't expose a stable public REST contract the way
`agent`'s and `mcp`'s own APIs do. It therefore also requires
`K6_BROWSER_ENABLED=true`; without it, only `agent` and `mcp` run.

`mcpScenario` speaks a minimal hand-rolled MCP client: an `initialize` call,
the required `notifications/initialized` notification, then one
`tools/call`, reusing the `Mcp-Session-Id` the server returns from
`initialize` on every following request - see the comments above
`mcpCallTool` in `script.js` for the protocol details.

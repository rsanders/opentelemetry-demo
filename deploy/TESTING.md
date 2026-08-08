# Testing

This covers two different things: the full build/test/report tooling added
alongside `deploy/` on this branch, and the test suites the upstream
`opentelemetry-demo` repo already ships. Run the former for a one-shot,
end-to-end check before pushing; reach for the latter pieces individually
while iterating on a single change.

## Full build, test, and report

[`full-build-test-report.sh`](../full-build-test-report.sh) (repo root) and
[`.github/workflows/full-build-test-report.yml`](../.github/workflows/full-build-test-report.yml)
run the same sequence — build every image, run the frontend test suite,
start the stack, run the telemetry integration tests against it — and print a
report with the current branch, `IMAGE_VERSION`, and the files changed vs
`main`.

```bash
./full-build-test-report.sh
```

Requires Docker running locally. It writes a timestamped
`full-build-test-report-<date>.md` in the repo root and exits non-zero if any
stage failed. The GitHub Actions version is manually triggered
(`workflow_dispatch`, Actions tab → "Full Build & Test Report") and publishes
the same report to the run's job summary instead of a file — use that when
you want the check to run on GitHub's infra rather than your laptop.

Both are additive: they call the same `make` targets documented below, they
don't replace or change upstream's own CI (`checks.yml`,
`run-telemetry-tests.yml`, `build-images.yml`), and neither is wired to
push/pull_request, so they don't add to CI cost on every commit.

## Upstream repo's tests

These are the test suites `opentelemetry-demo` already defines; the workflow
above just chains a subset of them together. Run them individually when
iterating on a specific change.

**Docs and formatting** — misspellings, markdown lint, license headers, and
broken links:

```bash
make check
```

**Telemetry schema** — validates `telemetry-schema/` (the Weaver registry)
against its own rules:

```bash
docker run --rm \
  --mount "type=bind,source=$(pwd)/telemetry-schema,target=/home/weaver/source,readonly" \
  otel/weaver:v0.22.1 \
  registry check -r source
```

**Frontend end-to-end tests** (Cypress):

```bash
make run-frontend-tests
```

**Telemetry integration tests** — starts the stack and verifies each service
actually emits the traces/metrics/logs it's supposed to, via
`test/telemetry`'s pytest suite. See
[`test/telemetry/README.md`](../test/telemetry/README.md) for the full
service/signal matrix and environment variables.

```bash
make run-telemetry-tests           # full scope, all services
make run-telemetry-tests-minimal   # minimal scope, faster
make run-telemetry-tests-agentic   # agent/mcp/chatbot scope
```

Each of these starts the demo stack, runs the test container against it, and
tears the stack down afterward (success or failure) — no separate `make
start`/`make stop` needed.

**Single-service manual check** — per [`CONTRIBUTING.md`](../CONTRIBUTING.md),
the fastest loop while iterating on one service:

```bash
make build service=<service-name>
make restart service=<service-name>
# or, if the demo isn't already running, or the change touches shared
# compose config, protobufs, or collector/frontend-proxy config:
make build service=<service-name>
make start
```

### Where these run in CI

- **`checks.yml`** — docs/lint checks, Weaver check, and image builds, on
  every PR and push to `main`.
- **`run-telemetry-tests.yml`** — full and minimal telemetry integration
  tests, gated on PR review approval (or dependabot PRs / push to `main`).
- **`run-agentic-telemetry-tests.yml`** — agentic-scope telemetry tests, same
  gating, only when agent/mcp/chatbot-related paths change.
- **`build-images.yml`** — rebuilds images on any `src/**` or `test/**`
  change, independent of the checks above.

None of these are affected by `full-build-test-report.yml` — it's a separate,
manually-triggered workflow for getting one consolidated report locally or
on-demand in Actions.

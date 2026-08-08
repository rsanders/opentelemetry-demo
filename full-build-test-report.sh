#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Local equivalent of .github/workflows/full-build-test-report.yml: build all
# images, run the frontend test suite, start the stack, run the telemetry
# integration tests against it, then print a pass/fail report with branch,
# version, and changed files vs main.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

touch .env.override

BRANCH=$(git rev-parse --abbrev-ref HEAD)
COMMIT=$(git rev-parse --short HEAD)
VERSION=$(grep -m1 '^IMAGE_VERSION=' .env | cut -d= -f2)

git fetch origin main --quiet 2>/dev/null || true
if [ "$BRANCH" != "main" ] && git rev-parse --verify --quiet origin/main >/dev/null; then
  DIFF_RANGE="origin/main...HEAD"
elif [ "$BRANCH" != "main" ] && git rev-parse --verify --quiet main >/dev/null; then
  DIFF_RANGE="main...HEAD"
else
  DIFF_RANGE="HEAD~1...HEAD"
fi
CHANGED_FILES=$(git diff --name-status "$DIFF_RANGE" 2>/dev/null)

run_stage() {
  local label="$1"; shift
  echo
  echo "==> ${label}"
  if "$@"; then
    echo "==> ${label}: PASSED"
    return 0
  fi
  echo "==> ${label}: FAILED"
  return 1
}

BUILD_RESULT=PASSED
run_stage "Build all images" make build || BUILD_RESULT=FAILED

FRONTEND_RESULT=PASSED
run_stage "Frontend tests (Cypress)" make run-frontend-tests || FRONTEND_RESULT=FAILED

export WARMUP_SECONDS="${WARMUP_SECONDS:-300}"
export POLL_TIMEOUT="${POLL_TIMEOUT:-240}"
export WARMUP_PROBE_TIMEOUT="${WARMUP_PROBE_TIMEOUT:-180}"
INTEGRATION_RESULT=PASSED
run_stage "Start stack + integration tests" make run-telemetry-tests-minimal || INTEGRATION_RESULT=FAILED

if [ "$INTEGRATION_RESULT" = FAILED ]; then
  docker compose logs --tail=100 || true
fi

# run-telemetry-tests-minimal tears the stack down itself on both success and
# failure; this is just a safety net in case it was interrupted before that.
make stop >/dev/null 2>&1 || true

icon() { [ "$1" = PASSED ] && echo "PASSED" || echo "FAILED"; }

REPORT_FILE="full-build-test-report-$(date +%Y%m%d-%H%M%S).md"
{
  echo "# Full Build & Test Report"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Branch | \`$BRANCH\` |"
  echo "| Version (IMAGE_VERSION) | \`$VERSION\` |"
  echo "| Commit | \`$COMMIT\` |"
  echo "| Run at | $(date -u +"%Y-%m-%dT%H:%M:%SZ") |"
  echo
  echo "## Results"
  echo
  echo "| Stage | Result |"
  echo "|---|---|"
  echo "| Build all images | $(icon "$BUILD_RESULT") |"
  echo "| Frontend tests (Cypress) | $(icon "$FRONTEND_RESULT") |"
  echo "| Start stack + integration tests | $(icon "$INTEGRATION_RESULT") |"
  echo
  echo "## Changed files (vs ${DIFF_RANGE})"
  echo
  echo '```'
  if [ -n "$CHANGED_FILES" ]; then echo "$CHANGED_FILES"; else echo "(none)"; fi
  echo '```'
} | tee "$REPORT_FILE"

echo
echo "Report written to ${REPORT_FILE}"

if [ "$BUILD_RESULT" = FAILED ] || [ "$FRONTEND_RESULT" = FAILED ] || [ "$INTEGRATION_RESULT" = FAILED ]; then
  exit 1
fi

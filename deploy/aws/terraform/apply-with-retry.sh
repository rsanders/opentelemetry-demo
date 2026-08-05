#!/usr/bin/env bash
# Wraps `terraform apply` to self-heal a specific, reproduced provider quirk:
# right after a `terraform destroy`, re-creating the /otel-demo/* CloudWatch
# log groups can fail with ResourceAlreadyExistsException even on a fresh
# apply -- the CreateLogGroup call actually succeeds on AWS's side, but the
# provider doesn't record it in state (looks like an internal request retry
# racing the real response). A plain sleep-and-retry doesn't help, since the
# resource genuinely already exists; the fix is to import it into state and
# retry the apply. Scoped defensively to ResourceAlreadyExistsException only
# -- any other failure is surfaced immediately, not silently retried.
set -u
cd "$(dirname "$0")"

MAX_ATTEMPTS=6
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  OUTPUT=$(terraform apply -input=false -auto-approve 2>&1)
  STATUS=$?
  echo "$OUTPUT"
  if [ "$STATUS" -eq 0 ]; then
    exit 0
  fi

  if ! echo "$OUTPUT" | grep -q "ResourceAlreadyExistsException"; then
    echo ">>> terraform apply failed for a reason other than ResourceAlreadyExistsException; not retrying." >&2
    exit "$STATUS"
  fi

  echo ">>> apply failed with ResourceAlreadyExistsException (attempt $attempt/$MAX_ATTEMPTS) -- importing the resource(s) it actually created on AWS's side, then retrying..." >&2

  ADDRS=$(echo "$OUTPUT" | grep -oE "with aws_cloudwatch_log_group\.[a-zA-Z0-9_]+")
  NAMES=$(echo "$OUTPUT" | grep -oE "Log Group \([^)]+\)" | sed -E 's/Log Group \((.*)\)/\1/')
  IMPORTED_ANY=false
  paste -d'|' <(echo "$ADDRS") <(echo "$NAMES") | while IFS='|' read -r with_addr name; do
    addr=$(echo "$with_addr" | grep -oE "aws_cloudwatch_log_group\.[a-zA-Z0-9_]+")
    if [ -n "$addr" ] && [ -n "$name" ]; then
      if terraform state list | grep -qx "$addr"; then
        echo "    $addr already in state, skipping import"
      else
        echo "    importing $addr <- $name"
        terraform import "$addr" "$name" || true
      fi
    fi
  done

  sleep 5
done

echo ">>> giving up after $MAX_ATTEMPTS attempts" >&2
exit 1

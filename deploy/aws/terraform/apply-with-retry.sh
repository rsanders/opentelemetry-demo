#!/usr/bin/env bash
# Wraps `terraform apply` to self-heal reproduced "already exists" quirks
# where the resource genuinely already exists on AWS's side but not yet in
# Terraform's state, so a plain sleep-and-retry doesn't help -- the fix in
# each case is to import the resource into state and retry the apply. Scoped
# defensively to these known error signatures only -- any other failure is
# surfaced immediately, not silently retried.
#
# 1. Right after a `terraform destroy`, re-creating the /otel-demo/*
#    CloudWatch log groups can fail with ResourceAlreadyExistsException even
#    on a fresh apply -- the CreateLogGroup call actually succeeds on AWS's
#    side, but the provider doesn't record it in state (looks like an
#    internal request retry racing the real response).
#
# 2. aws_cloudwatch_log_stream.app[*] (cloudwatch.tf) can fail the same way
#    with ResourceAlreadyExistsException. Reproduced concretely for the
#    "otel-collector" stream, a leftover from the retired awscloudwatchlogs
#    exporter (which auto-created it); could plausibly recur for any stream
#    name after a partial apply, same root cause as #1.
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

  # Checked before the log-group branch below: both errors share the
  # ResourceAlreadyExistsException string, so the more specific resource type
  # has to be matched first or a log-stream failure would fall into the
  # log-group branch's regex and silently match nothing.
  if echo "$OUTPUT" | grep -q "ResourceAlreadyExistsException" && echo "$OUTPUT" | grep -q "aws_cloudwatch_log_stream\."; then
    echo ">>> apply failed creating a log stream that already exists (attempt $attempt/$MAX_ATTEMPTS) -- importing it, then retrying..." >&2

    LOG_GROUP=$(terraform state show aws_cloudwatch_log_group.app 2>/dev/null | grep -E '^\s*name\s*=' | head -1 | sed -E 's/.*= *"(.*)"/\1/')
    if [ -z "$LOG_GROUP" ]; then
      echo "    could not determine the log group name from state; not retrying." >&2
      exit "$STATUS"
    fi
    echo "$OUTPUT" | grep -oE 'with aws_cloudwatch_log_stream\.[a-zA-Z0-9_]+\["[^"]+"\]' | sed -E 's/^with //' | sort -u | while read -r addr; do
      stream_name=$(echo "$addr" | grep -oE '\["[^"]+"\]' | tr -d '["]')
      if terraform state list | grep -qxF "$addr"; then
        echo "    $addr already in state, skipping import"
      else
        echo "    importing $addr <- $LOG_GROUP:$stream_name"
        terraform import "$addr" "$LOG_GROUP:$stream_name" || true
      fi
    done
  elif echo "$OUTPUT" | grep -q "ResourceAlreadyExistsException"; then
    echo ">>> apply failed with ResourceAlreadyExistsException (attempt $attempt/$MAX_ATTEMPTS) -- importing the resource(s) it actually created on AWS's side, then retrying..." >&2

    ADDRS=$(echo "$OUTPUT" | grep -oE "with aws_cloudwatch_log_group\.[a-zA-Z0-9_]+")
    NAMES=$(echo "$OUTPUT" | grep -oE "Log Group \([^)]+\)" | sed -E 's/Log Group \((.*)\)/\1/')
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
  else
    echo ">>> terraform apply failed for a reason other than the known already-exists quirks; not retrying." >&2
    exit "$STATUS"
  fi

  sleep 5
done

echo ">>> giving up after $MAX_ATTEMPTS attempts" >&2
exit 1

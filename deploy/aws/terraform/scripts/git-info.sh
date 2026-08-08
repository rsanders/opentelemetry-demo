#!/usr/bin/env bash
# `external` data source program (see git.tf): reports the repo remote,
# branch, commit, and commit timestamp of the checkout this Terraform config
# lives in, so they can be applied as default_tags. Falls back to "unknown"
# for any value it can't determine (e.g. no `origin` remote, detached HEAD
# with no branch, or run outside a git checkout at all) rather than failing
# the plan/apply.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."

repo=$(git config --get remote.origin.url 2>/dev/null || true)
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
commit=$(git rev-parse HEAD 2>/dev/null || true)
commit_timestamp=$(git show -s --format=%cI HEAD 2>/dev/null || true)

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

printf '{"repo":"%s","branch":"%s","commit":"%s","commit_timestamp":"%s"}\n' \
  "$(json_escape "${repo:-unknown}")" \
  "$(json_escape "${branch:-unknown}")" \
  "$(json_escape "${commit:-unknown}")" \
  "$(json_escape "${commit_timestamp:-unknown}")"

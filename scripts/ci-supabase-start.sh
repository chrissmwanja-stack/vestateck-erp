#!/usr/bin/env bash
# Start the local Supabase stack in CI, retrying only on infrastructure errors.
#
# `supabase start` pulls ~12 images from public.ecr.aws. Anonymous pulls are
# rate limited ("Rate exceeded"), and an interrupted pull leaves a half-created
# container holding port 54322 ("address already in use"), which makes the
# next attempt fail for a different reason. Both are runner flakes, not
# problems with the migrations.
#
# A failure that does NOT match a known infrastructure signature (for example
# a migration that errors during replay) fails immediately, so a real defect is
# never hidden behind retries.
#
# Usage: bash scripts/ci-supabase-start.sh [extra supabase start args]
set -uo pipefail

MAX_ATTEMPTS="${SUPABASE_START_ATTEMPTS:-3}"
LOG="$(mktemp)"
INFRA_PATTERN='Rate exceeded|toomanyrequests|address already in use|failed to bind host port|error from registry|TLS handshake timeout|i/o timeout|connection reset by peer|unexpected EOF|failed to start containers|context deadline exceeded'

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "::group::supabase start (attempt ${attempt}/${MAX_ATTEMPTS})"
  supabase start "$@" 2>&1 | tee "$LOG"
  rc=${PIPESTATUS[0]}
  echo "::endgroup::"

  if [ "$rc" -eq 0 ]; then
    exit 0
  fi

  if ! grep -qE "$INFRA_PATTERN" "$LOG"; then
    echo "::error::supabase start failed with a non-infrastructure error (exit ${rc}); not retrying."
    exit "$rc"
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    wait_s=$((attempt * 20))
    echo "::warning::supabase start hit an infrastructure error (attempt ${attempt}/${MAX_ATTEMPTS}); cleaning up and retrying in ${wait_s}s."
    # Remove half-started containers so the port is free for the next attempt.
    supabase stop --no-backup >/dev/null 2>&1 || true
    sleep "$wait_s"
  fi
done

echo "::error::supabase start failed ${MAX_ATTEMPTS} times with infrastructure errors."
exit 1

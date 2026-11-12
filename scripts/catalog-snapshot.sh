#!/usr/bin/env bash
# Compare (or update) the security catalog snapshot.
#
#   scripts/catalog-snapshot.sh <db-url>            check (default)
#   scripts/catalog-snapshot.sh <db-url> --check
#   scripts/catalog-snapshot.sh <db-url> --update   rewrite the committed snapshot
#
# The query is read-only (supabase/scripts/catalog_security_snapshot.sql), so it
# is safe to point at production to see whether production matches the repo:
#   scripts/catalog-snapshot.sh "$PROD_DATABASE_URL" --check
#
# Exit codes: 0 matches, 1 differs, 2 no committed snapshot yet (bootstrap),
#             3 could not run the query.
# The generated output is always written to $CATALOG_SNAPSHOT_OUT
# (default /tmp/security-catalog.txt) so CI can upload it as an artifact.
set -uo pipefail

DB_URL="${1:?usage: catalog-snapshot.sh <db-url> [--check|--update]}"
MODE="${2:---check}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQL="$ROOT/supabase/scripts/catalog_security_snapshot.sql"
SNAP="$ROOT/supabase/catalog-snapshots/security-catalog.txt"
OUT="${CATALOG_SNAPSHOT_OUT:-/tmp/security-catalog.txt}"

if ! psql "$DB_URL" -X -qAt -v ON_ERROR_STOP=1 -f "$SQL" | tr -d '\r' > "$OUT"; then
  echo "::error::could not run $SQL" >&2
  exit 3
fi
if [ ! -s "$OUT" ]; then
  echo "::error::snapshot query returned no rows" >&2
  exit 3
fi

case "$MODE" in
  --update)
    mkdir -p "$(dirname "$SNAP")"
    cp "$OUT" "$SNAP"
    echo "Wrote $(wc -l < "$SNAP") lines to ${SNAP#$ROOT/}. Review the diff, then commit it."
    exit 0 ;;
  --check) ;;
  *) echo "unknown mode: $MODE" >&2; exit 3 ;;
esac

if [ ! -f "$SNAP" ]; then
  echo "No committed snapshot at ${SNAP#$ROOT/}. Generated one at $OUT ($(wc -l < "$OUT") lines)." >&2
  exit 2
fi

if diff -u "$SNAP" "$OUT" > /tmp/security-catalog.diff; then
  echo "Security catalog matches the committed snapshot ($(wc -l < "$SNAP") facts)."
  exit 0
fi
echo "::error::Security catalog differs from supabase/catalog-snapshots/security-catalog.txt:"
cat /tmp/security-catalog.diff
echo
echo "If this change is intended (a grant, view option, RLS flag, search_path pin or"
echo "default privilege changed on purpose), run:"
echo "  scripts/catalog-snapshot.sh <db-url> --update"
echo "and commit the result. If it is NOT intended, a migration has loosened or reset"
echo "something (e.g. CREATE OR REPLACE VIEW dropping security_invoker)."
exit 1

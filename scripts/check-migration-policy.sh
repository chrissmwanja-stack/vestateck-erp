#!/usr/bin/env bash
# Enforces supabase/MIGRATION_POLICY.md against new migration files.
#
# Only checks files ADDED to supabase/migrations/ since the base ref --
# existing migrations (0001, 20260730143728, 20260806143936,
# 20260808143024) are grandfathered per the policy doc; rewriting them
# is Phase 1.5 (squash), not something this script should fight.
#
# Usage: scripts/check-migration-policy.sh [base-ref]
#   base-ref defaults to origin/main (fine for local/manual runs and for
#   pull_request CI, where origin/main is still the unmerged target
#   branch), falling back to HEAD~1 if origin/main isn't available (e.g.
#   a shallow checkout). For `push` CI runs, origin/main already
#   includes the pushed commit by the time the job runs, so the
#   workflow passes the pre-push SHA explicitly instead of relying on
#   this default -- see foundation-checks.yml.

set -euo pipefail

BASE_REF="${1:-origin/main}"
if ! git rev-parse --verify --quiet "$BASE_REF" > /dev/null; then
  BASE_REF="HEAD~1"
fi

NEW_MIGRATIONS=$(git diff --name-only --diff-filter=A "$BASE_REF"...HEAD -- supabase/migrations/ 2>/dev/null || true)

if [ -z "$NEW_MIGRATIONS" ]; then
  echo "check-migration-policy: no new migration files vs $BASE_REF. OK."
  exit 0
fi

FAIL=0

for f in $NEW_MIGRATIONS; do
  [ -f "$f" ] || continue

  # Strip full-line and trailing SQL comments before checking. Comments
  # (e.g. explaining a *past* violation being fixed) shouldn't trip the
  # same pattern as live SQL -- see 20260814150000_fix_all_seeded_users_
  # null_string_columns.sql, whose comment text contained the literal
  # string "insert into auth.users" while the SQL itself only UPDATEs.
  CODE=$(sed -E 's/--.*$//' "$f")

  if echo "$CODE" | grep -qiE 'insert\s+into\s+auth\.users'; then
    echo "FAIL: $f inserts into auth.users directly. Demo/test accounts belong in supabase/seed.sql, not a migration. (MIGRATION_POLICY.md, rule 1)"
    FAIL=1
  fi

  if echo "$CODE" | grep -qiE "crypt\(\s*'"; then
    echo "FAIL: $f contains a crypt('literal', ...) call -- looks like a committed password. (MIGRATION_POLICY.md, rule 2)"
    FAIL=1
  fi

  if echo "$CODE" | grep -qiE '\bfor\s+all\b'; then
    echo "FAIL: $f uses a 'FOR ALL' RLS policy. Split into SELECT/INSERT/UPDATE/DELETE. (MIGRATION_POLICY.md, rule 4)"
    FAIL=1
  fi

  if echo "$CODE" | grep -qiE 'tenant_id\s+uuid\s+not\s+null' && ! echo "$CODE" | grep -qiE 'references\s+(public\.)?tenants\s*\('; then
    echo "FAIL: $f adds a tenant_id column with no 'references tenants(id)' FK in the same file. (MIGRATION_POLICY.md, rule 5)"
    FAIL=1
  fi
done

if [ "$FAIL" -eq 1 ]; then
  echo ""
  echo "One or more new migrations violate supabase/MIGRATION_POLICY.md. See that file for the full rules."
  exit 1
fi

echo "check-migration-policy: $(echo "$NEW_MIGRATIONS" | wc -l | tr -d ' ') new migration(s) checked. OK."
exit 0

#!/usr/bin/env bash
# Enforces supabase/MIGRATION_POLICY.md against new migration files.
#
# Only checks files ADDED to supabase/migrations/ since the base ref --
# existing migrations are never re-checked. (The grandfathered ones were
# archived by the 2026-11 squash; see supabase/SQUASH_RUNBOOK.md.)
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

  # Filename must start with a real UTC timestamp, YYYYMMDDHHMMSS (rule 11).
  # The CLI cannot parse an impossible time such as hour 24 ("20261117240000"),
  # so `supabase migration list` prints the raw version instead of a date.
  # Validate the calendar value with date(1), not just the digit count.
  VERSION="$(basename "$f")"
  VERSION="${VERSION%%_*}"
  if ! [[ "$VERSION" =~ ^[0-9]{14}$ ]] \
     || ! date -u -d "${VERSION:0:4}-${VERSION:4:2}-${VERSION:6:2} ${VERSION:8:2}:${VERSION:10:2}:${VERSION:12:2}" +%Y%m%d%H%M%S 2>/dev/null \
          | grep -qx "$VERSION"; then
    echo "FAIL: $f does not start with a valid UTC timestamp (YYYYMMDDHHMMSS, hour 00-23, e.g. 20261118235900_name.sql). (MIGRATION_POLICY.md, rule 11)"
    FAIL=1
  fi

  # Strip full-line and trailing SQL comments before checking. Comments
  # (e.g. explaining a *past* violation being fixed) shouldn't trip the
  # same pattern as live SQL -- see 20260814150000_fix_all_seeded_users_
  # null_string_columns.sql, whose comment text contained the literal
  # string "insert into auth.users" while the SQL itself only UPDATEs.
  CODE=$(sed -E 's/--.*$//' "$f")
  has() { grep -qiE "$1" <<< "$CODE"; }

  if has 'insert\s+into\s+auth\.users'; then
    echo "FAIL: $f inserts into auth.users directly. Demo/test accounts belong in supabase/seed.sql, not a migration. (MIGRATION_POLICY.md, rule 1)"
    FAIL=1
  fi

  if has "crypt\(\s*'"; then
    echo "FAIL: $f contains a crypt('literal', ...) call -- looks like a committed password. (MIGRATION_POLICY.md, rule 2)"
    FAIL=1
  fi

  if has '\bfor\s+all\b'; then
    echo "FAIL: $f uses a 'FOR ALL' RLS policy. Split into SELECT/INSERT/UPDATE/DELETE. (MIGRATION_POLICY.md, rule 4)"
    FAIL=1
  fi

  if has 'tenant_id\s+uuid\s+not\s+null' && ! has 'references\s+(public\.)?tenants\s*\('; then
    echo "FAIL: $f adds a tenant_id column with no 'references tenants(id)' FK in the same file. (MIGRATION_POLICY.md, rule 5)"
    FAIL=1
  fi

  # Every new CREATE POLICY must name its role (rule 10). Without a TO clause a
  # policy applies to PUBLIC, i.e. also to `anon`. Flatten the file to one line,
  # cut each statement at its first USING / WITH CHECK (so a " to " inside an
  # expression cannot satisfy the check), and require a TO clause before that.
  BAD_POLICIES=$(echo "$CODE" | tr '\n' ' ' \
    | grep -oiE 'create[[:space:]]+policy[^;]*;' \
    | sed -E 's/[[:space:]](using|with[[:space:]]+check)[[:space:](].*$//I' \
    | grep -viE '[[:space:]]to[[:space:]]+[a-z_"]' || true)
  if [ -n "$BAD_POLICIES" ]; then
    echo "FAIL: $f has CREATE POLICY without a TO <role> clause (it would apply to PUBLIC, including anon). Add 'to authenticated'. (MIGRATION_POLICY.md, rule 10)"
    echo "$BAD_POLICIES" | sed 's/^/        /' | cut -c1-160
    FAIL=1
  fi

  # Filename check, not content -- a Studio/db-dump remote_schema file
  # is identified by how it was generated, not by any single SQL
  # pattern inside it. No dump remains in supabase/migrations/ since the
  # 2026-11 squash (MIGRATION_POLICY.md, rule 6); this only fires on new ones.
  if [[ "$(basename "$f")" =~ remote_schema\.sql$ ]]; then
    echo "FAIL: $f looks like a 'supabase db dump'/Studio-generated remote_schema file, not a hand-authored migration. Write the actual diff instead. (MIGRATION_POLICY.md, rule 6)"
    FAIL=1
  fi

  # Destructive DDL on an existing table. This is invisible to
  # db-shadow-replay (which runs against an empty DB) but destroys
  # real data on any database that already has rows -- see the
  # hr_payroll_items paye/nssf drop-then-recreate incident this rule
  # was added for. Matches "drop column" and "drop column if exists"
  # regardless of quoting; deliberately does not match DROP on brand
  # new objects created earlier in the same file (e.g. a scratch temp
  # table), since grep can't tell "existing" from "just-created" --
  # reviewers should still eyeball any DROP TABLE this doesn't catch.
  if has '\bdrop\s+column\b'; then
    echo "FAIL: $f contains DROP COLUMN. Deprecate instead: rename to <name>_deprecated, stop reading it, drop it in a separate migration next release. (MIGRATION_POLICY.md, rule 8)"
    FAIL=1
  fi

  if has '\bdrop\s+table\b(\s+if\s+exists)?\s+"?public"?\."?[a-z_]+"?\s*;' && ! has '\bcreate\s+(table|temp\s+table|temporary\s+table)\b'; then
    echo "FAIL: $f contains DROP TABLE on what looks like an existing table (no matching CREATE TABLE earlier in this file). Deprecate instead, or confirm with a human reviewer that this table is genuinely being retired. (MIGRATION_POLICY.md, rule 8)"
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

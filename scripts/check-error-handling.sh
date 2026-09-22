#!/usr/bin/env bash
# Guards against regressing two patterns the 22 Sept repo-state analysis
# flagged: native alert()/confirm() dialogs (114/50 call sites at audit
# time) and supabase calls that destructure `data` without `error`,
# silently swallowing a failed request (51 call sites at audit time).
#
# Both patterns already exist all over the app, so -- same approach as
# check-migration-policy.sh -- this only checks files ADDED since the
# base ref. Fixing the ~113 alert()/~49 confirm()/~51 swallowed-error
# call sites already in the tree is a separate, incremental module-by-
# module rollout (replace with useToast()/useConfirm() from
# src/lib/toastContext.tsx / src/lib/confirmContext.tsx), not something
# this script retroactively enforces.
#
# Usage: scripts/check-error-handling.sh [base-ref]
#   base-ref defaults to origin/main, falling back to HEAD~1 -- see
#   check-migration-policy.sh's header for why, and foundation-
#   checks.yml for how CI passes the right ref for push vs pull_request.

set -euo pipefail

BASE_REF="${1:-origin/main}"
if ! git rev-parse --verify --quiet "$BASE_REF" > /dev/null; then
  BASE_REF="HEAD~1"
fi

NEW_FILES=$(git diff --name-only --diff-filter=A "$BASE_REF"...HEAD -- 'apps/web/src/**/*.ts' 'apps/web/src/**/*.tsx' 2>/dev/null || true)

if [ -z "$NEW_FILES" ]; then
  echo "check-error-handling: no new frontend files vs $BASE_REF. OK."
  exit 0
fi

FAIL=0

for f in $NEW_FILES; do
  [ -f "$f" ] || continue

  # Test files legitimately reference alert()/confirm() as native APIs
  # only when spying on/mocking them for a *pre-existing* screen still
  # using the old pattern -- new test files for new screens have no
  # reason to. Skip test files rather than special-case that here.
  case "$f" in
    *.test.ts|*.test.tsx) continue ;;
  esac

  # Strip line AND block comments so a doc comment describing the old
  # pattern (e.g. "Replacement for native alert()") doesn't self-trigger.
  # python3's re with DOTALL handles multi-line /* */ blocks, which sed
  # can't do cleanly in one pass.
  CODE=$(python3 -c "
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
text = re.sub(r'//.*', '', text)
print(text)
" "$f")

  if echo "$CODE" | grep -qE '(^|[^.\w])alert\s*\('; then
    echo "FAIL: $f calls alert(). Use useToast() from src/lib/toastContext.tsx instead (showToast/showError/showSuccess)."
    FAIL=1
  fi

  if echo "$CODE" | grep -qE 'window\.confirm\s*\(' || echo "$CODE" | grep -qE 'if\s*\(\s*!?\s*confirm\s*\('; then
    echo "FAIL: $f calls confirm() synchronously. Use useConfirm() from src/lib/confirmContext.tsx instead -- it returns a Promise<boolean>, so call sites need 'if (!(await confirm(...)))'."
    FAIL=1
  fi

  # The exact shape of the ProposalApprovals.tsx bug this was written
  # after fixing: destructuring only `data` from a supabase call means
  # a failed RLS check or network error renders an empty/stale screen
  # with nothing telling the user why. Matches "const { data }" and
  # "const {data}" (no "error" anywhere on the same destructure) right
  # before "= await supabase". Doesn't try to catch every possible
  # variation (e.g. destructuring across multiple lines) -- a human
  # reviewer should still watch for those.
  if echo "$CODE" | grep -qE 'const\s*\{\s*data\s*\}\s*=\s*await\s+supabase'; then
    echo "FAIL: $f destructures only { data } from a supabase call, dropping { error }. Destructure both and surface a failed request via showError() -- see ProposalApprovals.tsx's fetchData() for the pattern."
    FAIL=1
  fi
done

if [ "$FAIL" -eq 1 ]; then
  echo ""
  echo "One or more new frontend files use a pattern this repo is moving away from. See the messages above."
  exit 1
fi

echo "check-error-handling: $(echo "$NEW_FILES" | wc -l | tr -d ' ') new frontend file(s) checked. OK."
exit 0
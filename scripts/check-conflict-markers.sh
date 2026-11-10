#!/usr/bin/env bash
# Fails if any tracked text file contains an unresolved git merge-conflict
# marker. Conflict markers have reached main twice (IN_FORCE_IMPORT.md, then
# database.types.ts) because nothing checked for them.
#
# Only the two unambiguous markers are matched: seven '<' or seven '>' at the
# start of a line, followed by a space or end of line. The '=======' separator
# is deliberately NOT matched on its own: it is also a valid Markdown (setext)
# heading underline, so matching it would raise false alarms. A real conflict
# always has the '<<<<<<<' and '>>>>>>>' lines anyway.
#
# Usage:  scripts/check-conflict-markers.sh            # check the working tree's tracked files
#         scripts/check-conflict-markers.sh <rev>      # check a commit (used for testing the check)
set -euo pipefail
REV="${1:-}"
PATTERN='^(<{7}|>{7})( |$)'
if [ -n "$REV" ]; then
  HITS="$(git grep -nIE "$PATTERN" "$REV" -- . || true)"
else
  HITS="$(git grep -nIE "$PATTERN" -- . || true)"
fi
if [ -n "$HITS" ]; then
  echo "check-conflict-markers: unresolved merge-conflict markers found:" >&2
  echo "$HITS" | cut -c1-200 >&2
  echo "Resolve them (keep the intended side, delete the marker lines) and commit again." >&2
  exit 1
fi
echo "check-conflict-markers: none found."

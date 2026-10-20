# Regenerates packages/shared/src/database.types.ts as UTF-8.
#
# Why cmd: in Windows PowerShell a plain `>` redirect writes UTF-16, which made
# this file unreadable to git diff and grep (12 Oct 2026 analysis, F4). cmd's
# redirect keeps the CLI's UTF-8 bytes unchanged.
#
# Usage (repo root):
#   .\scripts\gen-types.ps1            # from the linked live project
#   .\scripts\gen-types.ps1 -Local     # from the local stack (supabase start)
#
# CLI version: pinned to the version CI uses (supabase/setup-cli `version:` in
# .github/workflows/foundation-checks.yml). Keep the two equal. CI diffs this file against
# that CLI's output, and different CLI versions format it differently (comment lines under
# `export type Database`, parentheses in the Tables/Enums helper types). An unpinned
# `npx supabase` picks up whatever is installed and made the check fail on formatting alone
# (20 Oct 2026). Needs Docker running, as before.
param([switch]$Local)

$ErrorActionPreference = 'Stop'
$out = 'packages\shared\src\database.types.ts'
$cli = 'supabase@2.114.0'

if ($Local) {
  cmd /c "npx --yes $cli gen types typescript --local --schema public > $out"
} else {
  cmd /c "npx --yes $cli gen types typescript --project-id xownbroirovedkmqyybc --schema public > $out"
}
if ($LASTEXITCODE -ne 0) { throw "supabase gen types failed (exit $LASTEXITCODE)" }

# A UTF-16 file starts with a BOM (FF FE); fail loudly if one slipped in.
$head = [System.IO.File]::ReadAllBytes($out)[0..1]
if ($head[0] -eq 0xFF -and $head[1] -eq 0xFE) { throw "$out is UTF-16; regenerate it" }
Write-Host "Wrote $out"

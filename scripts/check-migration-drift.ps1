<#
.SYNOPSIS
  Detects drift between local Supabase migration files and what's actually
  tracked in the remote project's schema_migrations table.

.DESCRIPTION
  Wraps `supabase migrations list` (which already diffs local vs remote)
  and cross-checks it against the migration files actually present on
  disk, so drift like:
    - a migration applied directly via dashboard/MCP with no local file
      (e.g. 20260810070906_platform_admin_impersonation.sql before it
      was reconstructed)
    - a local file whose version doesn't match what's tracked remotely
      (e.g. the 20260808055749 / 20260813085312 rename)
    - a local file that exists but was never pushed
  is caught explicitly, with a non-zero exit code, instead of being
  something you have to notice by eye in a 150-row table -- or discover
  mid-`db pull` on a fresh environment.

.PARAMETER MigrationsPath
  Path to the local migrations folder. Defaults to ./supabase/migrations
  relative to the current directory.

.EXAMPLE
  ./scripts/check-migration-drift.ps1

.EXAMPLE
  ./scripts/check-migration-drift.ps1 -MigrationsPath supabase/migrations
#>

[CmdletBinding()]
param(
    [string]$MigrationsPath = "supabase/migrations"
)

$ErrorActionPreference = "Stop"

# PowerShell 7.3+ treats ANY stderr output from a native .exe as a
# terminating error when $ErrorActionPreference = "Stop", regardless of
# exit code. The supabase CLI writes normal progress messages (e.g.
# "Initialising login role...") to stderr, which would otherwise abort
# this script before we ever get to check $LASTEXITCODE. Harmless to set
# on older PowerShell versions that don't recognize this variable.
$PSNativeCommandUseErrorActionPreference = $false

function Write-Section($title) {
    Write-Host ""
    Write-Host "== $title ==" -ForegroundColor Cyan
}

if (-not (Test-Path $MigrationsPath)) {
    Write-Error "Migrations path not found: $MigrationsPath (run this from your repo root, or pass -MigrationsPath)"
    exit 2
}

Write-Section "Running 'supabase migrations list'"

# $ErrorActionPreference = "Stop" (set above) means ANY ErrorRecord
# terminates the script immediately -- and `2>&1` on a native command
# converts every stderr line into an ErrorRecord regardless of exit code
# or $PSNativeCommandUseErrorActionPreference (that setting only governs
# exit-code handling, not this stream conversion). The supabase CLI
# writes normal progress text ("Initialising login role...") to stderr,
# so relax ErrorActionPreference just for this one call, then restore it.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$raw = (supabase migrations list 2>&1 | Out-String)
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

if ($exitCode -ne 0) {
    Write-Host $raw
    Write-Error "supabase migrations list failed -- check your login/link state (supabase login / supabase link)."
    exit 2
}

# Parse the markdown-style table the CLI prints, e.g.:
#    `20260808055749` | `20260808055749` | `2026-08-08 05:57:49`
# A missing cell is the actual drift signal -- but it isn't guaranteed the
# CLI renders a missing cell as empty backticks (` `) rather than just
# blank space with no backticks at all. Split on the pipe delimiter and
# strip backticks per-cell instead of requiring backticks around every
# column, so a bare-blank cell isn't silently dropped from the parse.
$rows = @()
foreach ($line in ($raw -split "`n")) {
    if ($line -notmatch '\|') { continue }          # not a table row
    if ($line -match 'Local\s*\|\s*Remote') { continue }  # header row
    if ($line -match '^\s*-+\|') { continue }        # separator row

    $parts = $line -split '\|'
    if ($parts.Count -ne 3) { continue }

    $rows += [PSCustomObject]@{
        Local  = $parts[0].Trim().Trim('`').Trim()
        Remote = $parts[1].Trim().Trim('`').Trim()
        Time   = $parts[2].Trim().Trim('`').Trim()
    }
}

if ($rows.Count -eq 0) {
    Write-Error "Couldn't parse any rows out of 'supabase migrations list' output. CLI output format may have changed -- inspect it manually:`n$raw"
    exit 2
}

# Versions actually present as files on disk -- the real source of truth
# for "local", independent of what the CLI thinks.
$localFiles = Get-ChildItem -Path $MigrationsPath -Filter "*.sql" |
    ForEach-Object {
        if ($_.Name -match '^(\d+)_') { $matches[1] } else { $null }
    } | Where-Object { $_ -ne $null }

$localFileSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$localFiles)

$remoteOnly        = @()  # tracked remotely, no local match per the CLI
$listSaysLocalOnly = @()  # CLI says local-only (not pushed / not tracked remotely)
$fileNotInList     = @()  # exists on disk but never appears in the CLI table at all (sanity check)
$listedVersions    = [System.Collections.Generic.HashSet[string]]::new()

foreach ($row in $rows) {
    if ($row.Local)  { [void]$listedVersions.Add($row.Local) }
    if ($row.Remote) { [void]$listedVersions.Add($row.Remote) }

    if ($row.Remote -and -not $row.Local) {
        $remoteOnly += $row
    }
    if ($row.Local -and -not $row.Remote) {
        $listSaysLocalOnly += $row
    }
}

foreach ($v in $localFileSet) {
    if (-not $listedVersions.Contains($v)) {
        $fileNotInList += $v
    }
}

Write-Section "Result"
$hasDrift = $false

if ($remoteOnly.Count -gt 0) {
    $hasDrift = $true
    Write-Host "Applied remotely but NO local migration file:" -ForegroundColor Yellow
    $remoteOnly | ForEach-Object { Write-Host "  - $($_.Remote)  ($($_.Time))" }
    Write-Host "  -> Applied via dashboard/MCP and never committed. Reconstruct it (see how 20260810070906_platform_admin_impersonation.sql was handled) or it'll silently be missing on any fresh environment." -ForegroundColor Yellow
}

if ($listSaysLocalOnly.Count -gt 0) {
    $hasDrift = $true
    Write-Host "Local file exists but isn't tracked/applied remotely:" -ForegroundColor Yellow
    $listSaysLocalOnly | ForEach-Object { Write-Host "  - $($_.Local)" }
    Write-Host "  -> Either push it (supabase db push) or it's a stray/renamed file." -ForegroundColor Yellow
}

if ($fileNotInList.Count -gt 0) {
    $hasDrift = $true
    Write-Host "File on disk but its version never appears in 'migrations list' at all:" -ForegroundColor Yellow
    $fileNotInList | ForEach-Object { Write-Host "  - $_" }
    Write-Host "  -> Likely a filename typo or duplicate version number." -ForegroundColor Yellow
}

if (-not $hasDrift) {
    Write-Host "No drift detected -- local files and remote schema_migrations match." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Drift detected -- see above." -ForegroundColor Red
exit 1

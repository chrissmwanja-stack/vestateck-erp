<#
.SYNOPSIS
  PowerShell port of scripts/check-migration-policy.sh.

.DESCRIPTION
  Mirrors the shell script rule for rule, so it can be run on Windows where
  bash may resolve to the WSL relay stub and fail with execvpe(/bin/bash).

  Only files ADDED since the base ref are checked, exactly as the shell script
  does. Existing migrations are never re-checked -- three of them use hour 24
  and are grandfathered because they are already applied.

  Usage:  powershell -ExecutionPolicy Bypass -File check-migration-policy.ps1
          powershell -File check-migration-policy.ps1 -BaseRef HEAD~1

  Rules refer to supabase/MIGRATION_POLICY.md.
#>
param(
  [string]$MigrationsPath = 'supabase/migrations',
  [string]$BaseRef = ''
)

$SCRIPT_VERSION = 'v2 2026-11-18 19:05 UTC'

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$fail = 0

# Printed first, so it is obvious which copy is running. An old file left in
# Downloads will print v1 and no stamp at all -- check this line before reading
# any FAIL output.
Write-Host "check-migration-policy.ps1 $SCRIPT_VERSION"


if (-not $BaseRef) {
  $BaseRef = 'origin/main'
  git rev-parse --verify --quiet $BaseRef *> $null
  if ($LASTEXITCODE -ne 0) { $BaseRef = 'HEAD~1' }
}

$added = @(git diff --name-only --diff-filter=A "$BaseRef...HEAD" -- $MigrationsPath 2>$null)
if ($added.Count -eq 0) {
  Write-Host "check-migration-policy: no new migration files vs $BaseRef. OK."
  exit 0
}

$files = @()
foreach ($a in $added) { if (Test-Path -LiteralPath $a) { $files += Get-Item -LiteralPath $a } }
if ($files.Count -eq 0) {
  Write-Host "check-migration-policy: no new migration files vs $BaseRef. OK."
  exit 0
}

Write-Host "Checking $($files.Count) new migration file(s) vs ${BaseRef}:"
$files | ForEach-Object { Write-Host "  $($_.Name)" }

# Fixed local helpers. Written with plain string/array work rather than
# [datetime] parsing: ParseExact() round-tripped through ToString() uses the
# CURRENT CULTURE, and on a locale whose calendar or digits differ that returns
# a different string for every valid timestamp, so every file "fails" the
# check. Arithmetic on the digits cannot drift.
function Test-Stamp([string]$v) {
  if ($v -notmatch '^\d{14}$') { return $false }
  $y  = [int]$v.Substring(0, 4)
  $mo = [int]$v.Substring(4, 2)
  $d  = [int]$v.Substring(6, 2)
  $h  = [int]$v.Substring(8, 2)
  $mi = [int]$v.Substring(10, 2)
  $s  = [int]$v.Substring(12, 2)
  if ($y -lt 1900 -or $y -gt 9999) { return $false }
  if ($mo -lt 1 -or $mo -gt 12)   { return $false }
  if ($d -lt 1 -or $d -gt [System.DateTime]::DaysInMonth($y, $mo)) { return $false }
  if ($h -gt 23 -or $mi -gt 59 -or $s -gt 59) { return $false }
  return $true
}

$nowStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss', $inv)

foreach ($f in $files) {
  $name    = $f.Name
  $version = ($name -split '_')[0]

  # --- rule 11: valid UTC timestamp, hour 00-23 -------------------------
  if (-not (Test-Stamp $version)) {
    Write-Host "FAIL: $name does not start with a valid UTC timestamp (YYYYMMDDHHMMSS, hour 00-23, e.g. 20261118235900_name.sql). (rule 11)"
    $fail = 1
  }
  elseif ([string]::CompareOrdinal($version, $nowStamp) -gt 0) {
    # Not in the shell script. A perfectly valid timestamp can still be in the
    # FUTURE, which dates the migration to a day that has not happened and makes
    # it sort after work that does not exist yet.
    Write-Host "FAIL: $name is dated in the FUTURE ($version). Use a real past UTC time; now is $nowStamp. (rule 11)"
    $fail = 1
  }

  # Strip SQL line comments before content checks, so a comment describing a past
  # violation does not trip the same rule as live SQL.
  $code = (Get-Content -Raw -LiteralPath $f.FullName) -replace '(?m)--.*$', ''

  function Has([string]$pattern) { return [bool]([regex]::IsMatch($code, $pattern, 'IgnoreCase')) }

  if (Has 'insert\s+into\s+auth\.users') {
    Write-Host "FAIL: $name inserts into auth.users directly. Demo/test accounts belong in supabase/seed.sql, not a migration. (rule 1)"
    $fail = 1
  }
  if (Has "crypt\(\s*'") {
    Write-Host "FAIL: $name contains a crypt('literal', ...) call -- looks like a committed password. (rule 2)"
    $fail = 1
  }
  if (Has '\bfor\s+all\b') {
    Write-Host "FAIL: $name uses a 'FOR ALL' RLS policy. Split into SELECT/INSERT/UPDATE/DELETE. (rule 4)"
    $fail = 1
  }
  if ((Has 'tenant_id\s+uuid\s+not\s+null') -and -not (Has 'references\s+(public\.)?tenants\s*\(')) {
    Write-Host "FAIL: $name adds a tenant_id column with no 'references tenants(id)' FK in the same file. (rule 5)"
    $fail = 1
  }

  # --- rule 10: every new CREATE POLICY names its role ------------------
  # Flatten to one line, cut each statement at its first USING / WITH CHECK so a
  # " to " inside an expression cannot satisfy the check, then require a TO clause.
  $flat = $code -replace "`r?`n", ' '
  $policies = [regex]::Matches($flat, '(?i)create\s+policy[^;]*;')
  foreach ($p in $policies) {
    $head = [regex]::Replace($p.Value, '(?i)\s(using|with\s+check)\s*[\(\s].*$', '')
    if ($head -notmatch '(?i)\sto\s+[a-z_"]') {
      Write-Host "FAIL: $name has CREATE POLICY without a TO <role> clause (it would apply to PUBLIC, including anon). Add 'to authenticated'. (rule 10)"
      Write-Host ("        " + $head.Substring(0, [Math]::Min(160, $head.Length)))
      $fail = 1
    }
  }

  # --- rule 6: no Studio/db-dump files ----------------------------------
  if ($name -match 'remote_schema\.sql$') {
    Write-Host "FAIL: $name looks like a 'supabase db dump'/Studio-generated remote_schema file, not a hand-authored migration. Write the actual diff instead. (rule 6)"
    $fail = 1
  }

  # --- rule 8: no destructive DDL on existing tables --------------------
  if (Has '\bdrop\s+column\b') {
    Write-Host "FAIL: $name contains DROP COLUMN. Deprecate instead: rename to <name>_deprecated, stop reading it, drop it in a separate migration next release. (rule 8)"
    $fail = 1
  }
  if ((Has '\bdrop\s+table\b(\s+if\s+exists)?\s+"?public"?\."?[a-z_]+"?\s*;') -and
      -not (Has '\bcreate\s+(table|temp\s+table|temporary\s+table)\b')) {
    Write-Host "FAIL: $name contains DROP TABLE on what looks like an existing table (no matching CREATE TABLE earlier in this file). Deprecate instead, or confirm with a human reviewer that this table is genuinely being retired. (rule 8)"
    $fail = 1
  }
}

# --- ordering: one migration per version --------------------------------
# Across the whole directory: a clash with an already-committed migration is
# exactly what this catches, and it can never be a false positive.
$allFiles = Get-ChildItem -Path $MigrationsPath -Filter '*.sql'
$dupes = $allFiles | Group-Object { ($_.Name -split '_')[0] } | Where-Object { $_.Count -gt 1 }
foreach ($d in $dupes) {
  Write-Host "FAIL: version $($d.Name) is used by more than one migration: $($d.Group.Name -join ', ')"
  $fail = 1
}

if ($fail -eq 1) {
  Write-Host "FAILED: migration policy violations above."
  exit 1
}
Write-Host "OK: migration policy checks passed."
exit 0

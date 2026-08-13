# Scans supabase/migrations for the 4 patterns that have caused every
# `supabase db pull` shadow-replay failure so far in this session:
#   1. ALTER TABLE ... ADD COLUMN without IF NOT EXISTS
#   2. CREATE TABLE without IF NOT EXISTS
#   3. INSERT statements using hardcoded placeholder UUIDs (needs manual
#      check for ON CONFLICT -- too multiline/varied to detect reliably
#      by regex, so this just lists candidates for review)
#   4. Function names defined via CREATE OR REPLACE FUNCTION in more than
#      one migration file (signature-change risk -- the exact issue that
#      just broke get_my_approval_queue)
#
# Run from the erp-platform repo root. Writes migration-scan-report.txt
# in the current directory and also prints a summary to console.

$migrationsPath = "supabase\migrations\*.sql"
$report = @()

$report += "=== 1. ALTER TABLE ... ADD COLUMN missing IF NOT EXISTS ==="
$addColumnHits = Select-String -Path $migrationsPath -Pattern "add column\s+(?!if not exists)" -CaseSensitive:$false
foreach ($hit in $addColumnHits) {
    $line = "$($hit.Path):$($hit.LineNumber): $($hit.Line.Trim())"
    $report += $line
}
$report += "Total: $($addColumnHits.Count)"
$report += ""

$report += "=== 2. CREATE TABLE missing IF NOT EXISTS ==="
$createTableHits = Select-String -Path $migrationsPath -Pattern "create table\s+(?!if not exists)" -CaseSensitive:$false
foreach ($hit in $createTableHits) {
    $line = "$($hit.Path):$($hit.LineNumber): $($hit.Line.Trim())"
    $report += $line
}
$report += "Total: $($createTableHits.Count)"
$report += ""

$report += "=== 3. INSERT statements with hardcoded placeholder UUIDs (manual review needed for ON CONFLICT) ==="
$insertHits = Select-String -Path $migrationsPath -Pattern "'00000000-0000-0000-0000-" -CaseSensitive:$false
$insertFiles = $insertHits | Select-Object -ExpandProperty Path -Unique
foreach ($f in $insertFiles) {
    $report += $f
}
$report += "Total files with hardcoded placeholder UUIDs: $($insertFiles.Count)"
$report += ""

$report += "=== 4. Functions defined in more than one migration file (signature-change risk) ==="
$funcHits = Select-String -Path $migrationsPath -Pattern "create (or replace )?function\s+public\.(\w+)" -CaseSensitive:$false
$funcMap = @{}
foreach ($hit in $funcHits) {
    if ($hit.Line -match "function\s+public\.(\w+)") {
        $fname = $matches[1]
        if (-not $funcMap.ContainsKey($fname)) { $funcMap[$fname] = @() }
        $funcMap[$fname] += "$($hit.Path):$($hit.LineNumber)"
    }
}
foreach ($fname in $funcMap.Keys | Sort-Object) {
    if ($funcMap[$fname].Count -gt 1) {
        $report += "$fname (defined $($funcMap[$fname].Count) times):"
        foreach ($loc in $funcMap[$fname]) {
            $report += "    $loc"
        }
    }
}
$report += ""

$report | Out-File -FilePath "migration-scan-report.txt" -Encoding utf8
Write-Host "Report written to migration-scan-report.txt"
Write-Host ""
Write-Host "Summary:"
Write-Host "  ADD COLUMN without IF NOT EXISTS: $($addColumnHits.Count)"
Write-Host "  CREATE TABLE without IF NOT EXISTS: $($createTableHits.Count)"
Write-Host "  Files with hardcoded placeholder UUIDs: $($insertFiles.Count)"
Write-Host "  Functions defined more than once: $(($funcMap.Keys | Where-Object { $funcMap[$_].Count -gt 1 }).Count)"

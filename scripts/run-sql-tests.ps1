param(
  [string]$Container = "supabase_db_erp-platform",
  [string]$Dir = "supabase\tests"
)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$results = @()
foreach ($f in Get-ChildItem $Dir -Filter *.sql -Recurse | Sort-Object FullName) {
  $out = Get-Content $f.FullName -Raw -Encoding UTF8 |
    docker exec -i $Container psql -U postgres -d postgres -v ON_ERROR_STOP=1 2>&1 |
    Out-String
  $code = $LASTEXITCODE
  $checks = ([regex]::Matches($out, 'NOTICE:\s+PASS')).Count

  $results += [pscustomobject]@{
    File   = $f.Name
    Status = if ($code -eq 0) { 'PASS' } else { 'FAIL' }
    Checks = $checks
    Exit   = $code
  }

  if ($code -ne 0) {
    Write-Host "--- $($f.Name) (exit $code) ---" -ForegroundColor Red
    $out -split "`n" | Select-String 'ERROR|FAIL' | Select-Object -First 5
  }
}

$results | Format-Table -AutoSize
$failed = @($results | Where-Object Status -eq 'FAIL').Count
$color = if ($failed) { 'Red' } else { 'Green' }
Write-Host "$($results.Count - $failed) passed, $failed failed" -ForegroundColor $color

$global:LASTEXITCODE = $failed
return
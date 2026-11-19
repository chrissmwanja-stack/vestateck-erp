# Answers "is the work already in my tree?" before applying anything.
# Run from the repo root in PowerShell.
$ErrorActionPreference = 'Continue'

$markers = @(
  @{ Path = 'supabase/migrations/20261119210000_d4e_bank_adjustments_completion.sql'; What = 'D4e migration 1' },
  @{ Path = 'supabase/migrations/20261119235900_d4e_register_view_completion.sql'; What = 'D4e register view (renamed from ...240000)' },
  @{ Path = 'supabase/migrations/20261120000000_ins_commission_on_premium_collection.sql'; What = 'commission on collection' },
  @{ Path = 'supabase/migrations/20261120002000_ins_statutory_charge_catalogue.sql'; What = 'charge catalogue' },
  @{ Path = 'supabase/migrations/20261120003000_ins_charge_catalogue_extensible.sql'; What = 'charge catalogue extensible' },
  @{ Path = 'supabase/tests/test_ins_commission_on_premium_collection.sql'; What = 'test: commission on collection' },
  @{ Path = 'supabase/tests/test_ins_statutory_charge_catalogue.sql'; What = 'test: charge catalogue' },
  @{ Path = 'apps/web/src/features/financial/bank-reconciliation/useBankAdjustments.ts'; What = 'bank adjustments hook' },
  @{ Path = 'docs/handoffs/FINANCE_D4E_COMPLETION.md'; What = 'D4e handoff note' }
)

Write-Host "Markers present in this tree:" -ForegroundColor Cyan
$have = 0
foreach ($m in $markers) {
  if (Test-Path $m.Path) {
    Write-Host ("  [x] {0,-46} {1}" -f $m.What, $m.Path) -ForegroundColor Green
    $have++
  } else {
    Write-Host ("  [ ] {0,-46} {1}" -f $m.What, $m.Path) -ForegroundColor DarkGray
  }
}
Write-Host ""
Write-Host ("{0} of {1} markers present." -f $have, $markers.Count)

if (Test-Path 'supabase/migrations/20261119240000_d4e_register_view_completion.sql') {
  Write-Host "STALE FILE: 20261119240000_d4e_register_view_completion.sql is hour 24 and must not exist; delete it." -ForegroundColor Red
}
if (Test-Path 'supabase/migrations/20261119240000_ins_commission_on_premium_collection.sql') {
  Write-Host "STALE FILE: 20261119240000_ins_commission_on_premium_collection.sql is hour 24; it was renamed to 20261120000000." -ForegroundColor Red
}

Write-Host ""
if ($have -eq $markers.Count) {
  Write-Host "All markers present -- the work is ALREADY applied. Do not apply any patch." -ForegroundColor Yellow
  Write-Host "Next: git status, then .\scripts\gen-types.ps1 -Local" -ForegroundColor Yellow
} elseif ($have -eq 0) {
  Write-Host "None present -- clean tree. Apply the FLAT diff:" -ForegroundColor Cyan
  Write-Host "  git apply <path>\d4e-completion-v11-FLAT-FULL-from-origin-main.diff" -ForegroundColor Cyan
} else {
  Write-Host "PARTIAL state. Do not apply a cumulative patch on top of this." -ForegroundColor Red
  Write-Host "Reset only the paths this work touches, then apply the FLAT diff:" -ForegroundColor Red
  Write-Host "  git checkout -- supabase apps/web docs PHASE0_COUPLING_AUDIT.md packages" -ForegroundColor Red
  Write-Host "  git clean -fd supabase apps/web docs" -ForegroundColor Red
}

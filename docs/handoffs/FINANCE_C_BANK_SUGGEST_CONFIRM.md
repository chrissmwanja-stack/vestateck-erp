# Finance C — bank reconciliation: suggest and confirm

**Status:** done. Migration + test + desk wired. Full SQL suite 124/124 on a harness
rebuilt from scratch with `seed.sql`.

## What you asked for, against what already existed

| Part of C | Before | Now |
|---|---|---|
| Statement import | `import_bank_statement_lines` | unchanged |
| Auto-match | `auto_match_bank_statement` | unchanged |
| Manual match | 3 match RPCs + unmatch | unchanged |
| Unmatched queues | `v_bank_statement_unmatched`, `v_cash_bank_unmatched` | unchanged |
| Independent reviewer | enforced **server-side** for insurance cash | unchanged, now pinned by a test |
| Position report | `fin_bank_reconciliation_position` | unchanged |
| **Suggested matches** | **missing** | `fin_bank_suggested_matches` + confirm + review report |

## The correction worth recording

An earlier note in this project said the third-user rule for insurance cash
reconciliation was "enforced only in the client". **That was wrong.**
`ins_policy_cash_reconciliation_guard` raises `INS_CASH_THIRD_PERSON` (42501) when
the maker, checker or poster of an insurance cash request tries to reconcile it,
on INSERT, UPDATE and DELETE — and `auto_match_bank_statement` skips those
movements entirely. A probe settled it, and §5 of the new test now pins it so the
claim cannot drift back.

## The real gap

`fin_bank_line_candidates(line, tenant)` already computed which book entries
*could* match a statement line. But it was reachable only through
`auto_match_bank_statement`, which commits every unambiguous match in the window
with no review. A reconciliation desk wants to see the candidates and decide;
an auto-match that is wrong has to be found by reading a diff.

## What was added

**`fin_bank_suggested_matches(p_bank_account, p_date_from, p_date_to)`** — for
each unmatched statement line, up to three ranked candidates (tighter date first)
drawn from customer receipts, cash/bank movements, insurance cash, commission
transfers and procurement settlements. It **writes nothing**. Each row carries
`needs_third_user`, so the desk can say "this one needs someone else" *before*
attempting it.

**`fin_bank_confirm_match(p_statement_line_id, p_source, p_candidate_id)`** —
dispatches to the *existing* match RPCs
(`match_bank_statement_line`, `match_bank_statement_line_to_commission_transfer`,
`platform_ins_cxl_before_match_settlement`) so every existing validation, the
third-user rule and the audit trail still apply. Raises `CONFIRM_SOURCE` for an
unknown source and `CONFIRM_STALE` when the line or candidate has moved since the
suggestion was read. Returns the `bank_reconciliations` row.

**`fin_bank_reconciliation_review(p_bank_account_id, p_as_of)`** — how many
matches in the period were machine-made versus confirmed by a human, so
"auto-matched" is a reviewable number rather than a promise.

**`fin_bank_review_gaps(p_tenant_id, p_older_than_days)`** — accounts with
auto-matches nobody has looked at, and the oldest unreviewed date.

All four are finance-gated and tenant-scoped; the suggestion and review functions
are `security definer` with a pinned `search_path` because they aggregate across
tables the caller need not read row-by-row, and they check
`is_finance_team_member('finance')` rather than relying on "RLS returned zero
rows" as a refusal.

## Desk

- `useReconciliationData` fetches the queue alongside the existing queries.
- `SuggestedMatchesTable` groups by statement line, shows the
  **Needs a third Finance user** chip, and offers **Confirm** or **Pick by hand**.
  It keeps its own error slot, so a queue that fails to load never blocks manual
  matching.
- `BankReconciliation` confirms through `fin_bank_confirm_match` and reports the
  server's refusal rather than swallowing it.

## Verification

- `supabase/tests/test_fin_bank_reconciliation_suggest.sql` — 8 sections, all
  pass: ≤3 ranked per line, read-only, confirm writes `match_type='manual'` with
  `matched_by` set, `CONFIRM_STALE`/`CONFIRM_SOURCE`, third-user rule refused by
  the database *and* flagged in the queue first, review separates machine from
  human, gap report, finance-gated and tenant-scoped.
- Full SQL suite on a from-scratch harness + seed: **124 passed, 0 failed**.
- `check_live_security_drift.sql`: live security catalog matches expectations.
- `BankReconciliation.test.tsx`: 16/16, including the third-user warning and the
  "queue failed, manual matching still works" path.

## Not done (unchanged from before this work)

No browser end-to-end test of the reconciliation desk; the `tenant_id`-only
tables noted earlier still lack foreign keys.

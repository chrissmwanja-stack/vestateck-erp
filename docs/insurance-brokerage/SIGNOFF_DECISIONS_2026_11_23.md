# Accountant pack v2 — decisions log (23 November 2026)

The decisions that produced `ACCOUNTANT_PACK.md` v2, with the code impact of each. Recorded
because the migration comments argue *against* some of what v2 now does: a future reader needs
to see that the reversal was deliberate and who decided it, not infer that someone misread the
old code.

**Status of the two documents:** v2 is the policy of record. v1 (`ACCOUNTANT_PACK_v1_superseded.md`)
is withdrawn and is not for review.

| # | Decision | Code impact | Where |
|---|---|---|---|
| 1 | `pro_rata_on_collection` added as a fourth recognition mode. Binary `on_premium_collection` preserved for all-or-nothing agreements. | New setting value, new reader, new mode-aware routing on the receipt triggers | `20261124010100`, `20261124010200`, `test_ins_commission_pro_rata.sql` |
| 2 | Recognition mode is fail-closed: a company with no approved mode cannot bind. No silent fallback to `on_insurer_settlement`. | `ins_snapshot_bind_config` tests the setting **source**, not its value | `20261124010200` |
| 3 | Claims: build the stage model and the two review states now; beneficiaries, death claims, instalments and recoveries registered as committed-but-unbuilt. | B5 in UAT scope; B8, B10 registered | `signoff-register.json` |
| 4 | Unallocated client advances built now — liability account, receipt tracking, allocation and release on bind. | New account 2040 and role `client_advance_payable` | B2 (not yet migrated) |
| 5 | `ins.broker_fee_vat` removed, not repointed. Decision history retained in documentation. | Setting deleted; classification via `fee_class` is the control | `20261124010000` |
| 6 | v2 replaces `ACCOUNTANT_PACK.md`; v1 archived as `ACCOUNTANT_PACK_v1_superseded.md`. | — | this folder |
| 7 | Register is machine-readable; CI validates settings against implemented values. | JSON + generator + validator + two CI steps | `signoff-register.json`, `scripts/`, `foundation-checks.yml` |
| 8 | Sign-off is for the production accounting policy, with UAT acceptance and production go-live as separate gates. | A/B split with `blocking_gate` / `blocks` on every row | `ACCOUNTANT_PACK.md` §1, §16 |

## Why decision 2 tests the source, not the value

`acct_get_setting()` returns `source = 'default'` when no company row is in force, and the seeded
`default_value` for `ins.commission_recognition` is still `'on_insurer_settlement'`
(`20261120001000` left it there on purpose). Checking the *value* would therefore never detect a
company that never chose — the default and an explicit choice would be indistinguishable. The guard
checks `source`, so:

- no approved company row → `default` → **bind refused**, with an error naming the policy, the
  effective date and the four valid modes;
- an explicit choice, *including* one that chose `on_insurer_settlement` → `configured` → **bind
  proceeds**.

That is the difference between "we defaulted you to something" and "you chose".

## Why decision 1 added a mode instead of changing one

`on_premium_collection`'s binary rule is not a bug: for an agreement whose entitlement arises only
when the premium is fully paid, recognising a proportion on a part payment would invent an
entitlement the agreement does not create. Re-interpreting it as pro-rata would have silently moved
revenue between periods for every agreement already configured that way. So the proportional rule is
a *new* mode, and the two now behave demonstrably differently — §3 and §7 of
`test_ins_commission_pro_rata.sql` are the evidence.

## What is deliberately left open

- **B1 accepts that the mode is not finished until the test has run.** The register keeps
  `implemented: false` for A3/A4 and says why. Flip it only after
  `test_ins_commission_pro_rata.sql` passes on a clean replay.
- **B2 (unallocated advances) is decided but not migrated** — it needs account 2040 and a release
  path, and the chart does not have that account yet.
- **B5, B8, B10 (claims)** are registered, not built.
- **Legal and accounting questions** remain open in `ACCOUNTANT_PACK.md` §4.2, §12.1 and §12.3:
  the s.90(3) set-off question, the two unverified statutory rates, and client-side WHT on
  client-paid fees.

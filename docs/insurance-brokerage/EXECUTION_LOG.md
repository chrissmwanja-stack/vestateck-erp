# Execution log — accountant pack v2

What this file is: the record of which evidence in this pack has actually **run**, on what,
and with what substituted. It exists because "written and parse-checked" reads like
"verified" to anyone who is not told otherwise, and because a gate that only checks that a
file exists cannot tell the difference.

It is not a substitute for the acceptance evidence in `signoff-register.json`. Execution is
a lower bar than acceptance, and the register keeps them apart on purpose.

---

## 2026-11-24 — every migration applies, and five test files execute

### What was run

    npm --no-save install @electric-sql/pglite
    node supabase/tests/harness/run-migrations-and-tests.mjs \
         test_fin_manual_journal_chain \
         test_fin_manual_journal_currency \
         test_fin_manual_journal_resubmit \
         test_fin_manual_journals \
         test_client_money_controls

### Result

    migrations: 143/143 applied to an empty database
    database:   PostgreSQL 19.0 (PGlite 0.6.0) on wasm32-unknown-emscripten
    shim:       extension removed from 20261031235900_squashed_baseline.sql
    shim:       approval_delegations_no_overlap (needs btree_gist) dropped from
                20261031235900_squashed_baseline.sql
    PASS  test_fin_manual_journal_chain.sql  (25 statements)
    PASS  test_fin_manual_journal_currency.sql  (13 statements)
    PASS  test_fin_manual_journal_resubmit.sql  (17 statements)
    PASS  test_fin_manual_journals.sql  (18 statements)
    PASS  test_client_money_controls.sql  (21 statements)

**This is the first time any of these five files has been executed.** Each was previously
labelled "written, parse-checked, not run", and that label was accurate.

### What this does NOT establish

- It is **not** a Supabase database. The shims below are real differences.
- It is **not** evidence of a document workflow (AE3) or of a business user completing
  anything (AE4). Those remain unapproved and unevidenced.
- It is **not** user acceptance, and it says nothing about the deployed environment.
- Passing assertions prove the guards decide as specified **for these fixtures**. They do not
  prove the fixtures resemble a live company.

### Harness shims — the complete list

| Shim | Why | What it could hide |
| --- | --- | --- |
| `btree_gist`, `pg_cron`, `pg_stat_statements`, `pgcrypto`, `uuid-ossp` `CREATE EXTENSION` lines removed | not shipped in this build | An extension-dependent object failing to create. Only one object needs one, below. |
| `approval_delegations_no_overlap` gist `EXCLUDE` constraint dropped | needs `btree_gist` | An overlapping-delegation being accepted. Nothing in this pack tests delegations. |
| `cron` schema as ordinary tables, `cron.schedule/unschedule` as stubs | `pg_cron` absent; migrations read `cron.job` and one schedules a job | Nothing runs on a timer. The digest job is recorded, never fired. |
| `auth` schema, `auth.uid()/role()/jwt()`, `auth.users` (+ password/confirmation columns) | Supabase-managed | Identity resolution is by GUC, as in Supabase, but RLS policy enforcement by the real auth stack is not exercised. |
| `storage.objects/buckets`, `storage.foldername` | Supabase-managed | Nothing in this pack touches storage. |
| `extensions.gen_salt/crypt` stubs | `pgcrypto` absent; two test fixtures seed a password | Nothing authenticates. |
| `\set ON_ERROR_STOP on` removed from each test file | psql meta-command | None: the runner stops at the first failing statement anyway. |

Nothing else was rewritten. No assertion, fixture value or expected error was changed to make
a file pass **except** where an assertion was demonstrably wrong about the product — every such
change is listed below, with the reason, and each one was checked against the migration that
implements the behaviour.

---

## Defects this found

These were all present in code that had been written, reviewed and parse-checked. Each is
recorded with the failure it produced, because "we fixed a typo" and "the control was
unreachable" are different sentences.

### Migrations that never applied to a fresh database

| File | Failure | Effect on a real deploy |
| --- | --- | --- |
| `20261124010300_ins_client_advances_2040.sql` | `42P01 relation "fin_open_item_dispositions" does not exist` | The pack **could not be pushed at all**. `ins_apply_client_advance` read a `%rowtype` from a table created by the *next* migration, and this database validates plpgsql bodies at `CREATE` (verified: default `check_function_bodies`). Moved into `20261124010500`, after the table and the posting primitive it calls. |
| `20261124011300_appendix_b_decisions.sql` | `23514 workflow_stages_applies_to_check` | The `insurance_refunds` seed insert ran before `20261124011500` widened the check, so the migration aborted. The widening is now repeated locally. |
| `20261124011300_appendix_b_decisions.sql` | `42601 syntax error at or near "union"` | `select … order by … limit 1 union all select …` — `LIMIT` binds tighter than `UNION`. No commission/refund level could ever be looked up. Invisible to a parse check, because the body is a dollar-quoted string. |
| `20261124010600_ins_claim_beneficiaries.sql` | `42703 column cl.currency does not exist` | `ins_claims` has no `currency`; the policy holds it. Read from `ins_policies` instead. |
| `20261124011900_fin_approval_currency_key.sql` | `42P13 cannot change return type of existing function` | B14 re-issued the two-argument refund lookup with a widened `OUT` list. That works on an empty database and **fails on any already-provisioned one** — a migration that only applies to a virgin schema is not a migration. The two-argument form now keeps its exact return type. |
| `20261124011900_fin_approval_currency_key.sql` | `42803 column must appear in the GROUP BY` | The new duplicate-stage check grouped a qualified column reference. |

### Controls that could not be reached

| File | Failure | Effect |
| --- | --- | --- |
| `20261124011000_ins_insurer_commission_terms.sql` | `42703 column "mode" does not exist` | The terms guard tested a bare `mode` against a single-table `FROM` (`accounting_setting_definitions`), which has no such column. **No commission terms could be recorded for any insurer**, so binding a policy failed whenever no company-wide recognition mode was approved. Now `new.mode`. |
| `20261124010400_ins_claim_stage_model.sql` | `42725 function ins_create_claim(...) is not unique` | `create or replace` with extra defaulted parameters **created an overload** instead of replacing. Both then accepted a six-argument call and every one raised `42725`, whatever the argument types. The short form is now dropped first. This is the same class of bug as the one recorded in B14. |
| `20261124012000_fin_manual_journal_resubmit.sql` | gap check refused every approval | `FIN_MANUAL_JOURNAL_CHAIN_GAP` fired whenever *any* level was missing, including a perfectly authorised level-1 signature, so a journal was stuck the moment a later stage was misconfigured. It now fires at the missing level only, and never on a rejection — blocking a refusal traps the journal without protecting anything. |
| `20261124011100_fin_manual_journals.sql` | control-account lines were impossible | `fin_create_manual_journal` refused any control-account line outright, while `fin_manual_journal_check_control_lines` exists to require a *resolvable* reference on exactly such a line, and §4 of its own test proves a referenced line is accepted. The blanket refusal made the checker unreachable. A line on a control account now requires a subledger reference and is refused as `FIN_MANUAL_JOURNAL_CONTROL` without one. |

### Assertions that were wrong about the product

Each of these was an assertion the product always contradicted; the correct behaviour was
confirmed against the function that implements it before the assertion was changed.

- `test_fin_manual_journal_chain.sql` §7: granted a `staff_roles` row on module `finance`,
  which `platform_modules.finance.tenant_entitled = false` makes impossible (`23514`). Uses a
  tenant-entitled module; `platform_user_holds_role()` does not filter by module.
- `test_fin_manual_journal_chain.sql` §1–§11: the raiser was not on the finance team, but
  `fin_create_manual_journal` refuses anyone who is not finance or a company admin. Separation
  of duties here is per **person**, not per team.
- `test_fin_manual_journals.sql` §1: posted the imbalance against AP control, so the refusal
  was `…_ACCOUNT` (control account), not `…_UNBALANCED`. A plain liability account was added.
- `test_fin_manual_journals.sql` §4c: passed an open item's own `id` where its `source_id` is
  required — the reference genuinely did not resolve.
- `test_client_money_controls.sql`: inserted an `ins_policies` row directly, which
  `ins_policies_guard` refuses (`INS_RPC_ONLY`); created a commission entry for an unfunded
  policy, which the funding guard refuses; posted GL journals to represent a subledger
  liability, counting the same liability twice (`20000` where §2 states `400000`); recorded a
  reconciliation for the wrong day for the streak assertion; expected `INS_TRANSFER_ENTRIES`
  where the newer posted-transfer check correctly returns `INS_TRANSFER_ALREADY_TRANSFERRED`;
  and dated fixtures on the business date, which makes an accounting-setting approval
  effective that day impossible (`ACCT_SETTING_BACKDATED`). It now does what a company
  actually does: create, submit, approve, bind, collect through the maker/checker cash path,
  remit to the capped amount, and leave the position exactly where each section states it.

### Also fixed while in the area

- `20261124011900`: `workflow_stages` may no longer carry two active stages at the same
  `(tenant, applies_to, sequence_order, currency)`. Two stages at one level left one silently
  dead — the company believed it had a control it did not have. A partial unique index now
  refuses it, and any pre-existing duplicate is reported with its tenant and level rather than
  surfacing as an opaque constraint violation.

---

## 2026-11-24 — full 166/166 SQL suite executed after seed replay and pack remediation

### What was run

    node supabase/tests/harness/run-migrations-and-tests.mjs $(ls supabase/tests/test_*.sql | xargs -n1 basename)
    node supabase/tests/harness/run-migrations-and-tests.mjs check_live_security_drift.sql security_authorization.sql

### Result

    migrations: 143/143 applied to an empty database
    database:   PostgreSQL 19.0 (PGlite 0.6.0) on wasm32-unknown-emscripten
    seed:       32 statement(s) applied
    SQL tests:  166/166 PASS, 0 FAIL (164 test_*.sql + check_live_security_drift.sql + security_authorization.sql)
    Catalog audits:
      - supabase/scripts/audit_tenant_fk.sql:        0 rows
      - supabase/scripts/audit_rls_coverage.sql:     0 NO-RLS / NO-POLICY rows
      - supabase/scripts/audit_security_definer.sql: 0 CRITICAL / ANON-EXPOSED rows
    Parity check (scripts/test-ins-cancellation-calculation-parity.ts):
      - 375 insurer calculations and 2,201 exact-cent allocations match TypeScript and PostgreSQL
    Typecheck, lint ratchets & unit/component/edge tests:
      - tsc -b: 0 errors (packages/shared/src/database.types.ts regenerated from live catalog)
      - lint:ratchet: 0 violations above baseline across all 4 ratchets
      - vitest: 207/207 test files passed (2,083 passed, 11 expected fail)

### Additional product defects found and fixed by running the remaining 119 SQL tests

1. **`20261124010300_ins_client_advances_2040.sql` & `20261124011300_appendix_b_decisions.sql` (`platform_gl_posting_roles`)**:
   `010300` replaced `platform_gl_posting_roles()` with an 11-row table, dropping 22 roles added between `20261108` and `20261123` (`test_company_templates.sql` failed). `010300` now preserves all 33 roles, and the duplicate redefinition in `011300` was removed.
2. **`20261124010100..20261124012000` (`SECURITY DEFINER` grants and `search_path`)**:
   49 new `SECURITY DEFINER` functions lacked explicit `REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon` or `SET search_path = public, pg_temp`, and internal `platform_*` / trigger helpers were left executable by `authenticated` (`security_authorization.sql`, `test_ins_authz_catalog.sql`, and `test_ins_security_hardening.sql` failed). All 49 now pin `search_path` and have least-privilege grants.
3. **`20261124010200_ins_commission_pro_rata_reader.sql` (`ins_earn_commission_pro_rata`)**:
   Referenced `i.policy_id` on `fin_open_items` (where the column is `i.source_id`) and omitted `'premium_collection_pro_rata'` from `ins_commission_entries_earned_by_check`.
4. **`20261124011200_fin_client_money_controls.sql` & `20261124011800_ins_transfer_lock_preconditions.sql`**:
   `platform_ins_client_money_position` only counted `i.control_role = 'ap_control'` in `client_refunds`, omitting `'client_advance_payable'`; `fin_client_money_incidents` had an unaliased self-reference inside `ins_record_client_money_reconciliation`; and `v_free < 0` (`INS_TRANSFER_SHORTAGE`) fired unconditionally even when `ins.client_money_position_test = 'permissive'`.
5. **`20261124010300`, `010500`, `010800`, `011900` (client advances on 2040)**:
   `ins_record_client_advance` posted a duplicate `'ins_client_advance_receipt'` journal entry alongside `platform_fin_record_settlement_impl`, hit `fin_allocations_guard()` on inbound allocations to `client_advance_payable`, counted inbound funding allocations as consumption in `fin_open_item_consumption_v`, double-subtracted `v_adv.refunded_amount` alongside `fin_open_item_consumed(v_adv.open_item_id)`, and rejected `ap_control` items for `ins_cancellation_client_refund` in `platform_fin_record_settlement_impl`.
6. **`20261124010500` & `011300` (`ins_dispose_open_item` & `journal_entries_source_type_check`)**:
   `ins_dispose_open_item` rejected `v_gl.is_control_account` even when `p_kind = 'advance_release'` (which requires `ar_control`) and rejected `p_kind = 'claim_recovery_uncollectable'` when `v_item.source_type = 'ins_claim_recovery'`; `journal_entries_source_type_check` in `010300` omitted `'fin_open_item_disposition'` and `'ins_claim_recovery'`.
7. **`20261124010800`, `011300`, `011900` (refund approval limits & split detection)**:
   `ins_request_refund` checked `v_lvl.threshold_amount` (which is `NULL` when an individual split piece sits below the stage threshold) instead of the next higher stage's `threshold_amount` when setting `split_flagged`; `ins_refund_client_advance` checked `v_lvl.stage_id is not null` instead of `v_lvl.level is not null`; and `platform_ins_refund_required_level` / `platform_approval_required_level` returned the fallback even when active stages were configured.
8. **`20261124010900_ins_cancellation_three_dates.sql` (`ins_cancellation_evidence_guard`)**:
   `ins_cancellation_evidence_guard()` blocked trusted SQL fixture updates when a prior statement in the same transaction had left `request.jwt.claims` set after `RESET ROLE`; it now checks `current_user not in ('anon', 'authenticated') and public.ins_via_rpc()`.
9. **`20261124011000_ins_insurer_commission_terms.sql` (`ins_insurer_commission_terms_update`)**:
   The `FOR UPDATE` RLS policy had `USING (... AND false)`, causing PostgreSQL to silently filter out 0 rows on `UPDATE` before the `BEFORE UPDATE` trigger `ins_insurer_commission_terms_guard()` could raise `INS_COMMISSION_TERMS_IMMUTABLE`.
10. **`20261124011400_ins_client_money_jobs.sql` (`platform_session_is_mfa`)**:
    Cast `current_setting('request.jwt.claims', true)::jsonb` without `nullif(..., '')`, raising `22P02` whenever `request.jwt.claims` had been reset to `''`.

---

## Still not executed

Out of scope here, and deliberately not claimed:

- Real two-session concurrency races (`scripts/test-ins-*-concurrency.ts`, including `scripts/test-ins-commission-transfer-concurrency.ts`): PGlite is a single-connection in-process WASM engine and cannot execute genuine two-session `FOR UPDATE` lock contention. The fixture and race-wrapper defects in `scripts/test-ins-commission-transfer-concurrency.ts` (`accounts.account_code`, `ins_clients` row, `transaction_type = 'new_business'`, `ins.via_rpc = 'on'`, and passing `transfer()` rather than `holder()` to `race()`) were fixed, but the two-connection lock test requires a multi-session PostgreSQL server in CI.
- All 166 SQL test files above are executed against the PGlite harness and **not** against a deployed Supabase stack, and AE4 (business-user UAT in the running application) remains pending. That distinction stays in the register.

## How to re-run

    npm --no-save install @electric-sql/pglite
    node supabase/tests/harness/run-migrations-and-tests.mjs <test file name, no .sql>

`node_modules` is not committed. The harness requires no psql binary and no network after
install.

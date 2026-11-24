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

## Still not executed

Out of scope here, and deliberately not claimed:

- `test_ins_core.sql` reaches statement 21 of 22 on this harness and stops on a stale
  expectation: a direct policy status change is now refused by the fail-closed
  commission-recognition reader (alphabetically earlier trigger) rather than by
  `INS_STATUS_RPC_ONLY`. Both refusals are correct; the assertion names the older one.
- Every other test file in `supabase/tests/` that was never runnable in this environment.
- The five pack files above are executed against this harness and **not** against a Supabase
  project. That distinction stays in the register.

## How to re-run

    npm --no-save install @electric-sql/pglite
    node supabase/tests/harness/run-migrations-and-tests.mjs <test file name, no .sql>

`node_modules` is not committed. The harness requires no psql binary and no network after
install.

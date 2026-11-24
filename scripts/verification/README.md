# Verification helpers

These are not tests. They are the checks that caught defects the existing gates could not
see, kept here so the same class of defect can be caught again without re-deriving them.

Each one exists because a real bug in this branch got past everything else.

## `reissue_trace.py` — did re-issuing a live function change its behaviour?

```bash
python3 scripts/verification/reissue_trace.py \
  <old.sql> <new.sql> <function_name> [<function_name> ...]
```

Traces which refusals a function raises, which locals it assigns, and in what order, then
compares the old and new versions. Formatting and comments are ignored on purpose.

**Why:** `INS_TRANSFER_TRUST_SHORT` in `20261124011200` was moved above the `array_agg` that
assigns `v_total`. With `v_total` null the comparison `v_trust < v_total` is null, the `IF`
is skipped, and the refusal could never fire — while being plainly visible in the text. It
parses. It diffs as a move. Only an order-aware trace shows it.

Implementation note: the first version of this tool reported false "lost" events for two
reasons worth knowing before extending it. It searched for bare `fn(` and so missed
`public.fn(`, and it treated `insert into <table>` as a variable assignment because a bare
`into` matches both.

## `outparam_scan.py` — a RETURNS TABLE parameter colliding with a column

```bash
python3 scripts/verification/outparam_scan.py            # all supabase/migrations/2026*.sql
python3 scripts/verification/outparam_scan.py file.sql   # one file
```

**Why:** a name that is both an OUT parameter and a column raises `42702 column reference
is ambiguous`. Which positions raise was measured on PostgreSQL, not assumed:

| Position | Raises 42702? |
|---|---|
| `return query select <bare name>` | **yes** |
| `for ... in select ... where <bare name>` | **yes** |
| DML `where <bare name>` (`select into`, `update ... where`) | no |
| `order by <bare name>` | no — resolves to the output column |
| named notation `callee(name => ...)` | no |
| alias list `as r(a, b, c)` | no |

So a hit here is a prompt to look, not a verdict. The tool is deliberately noisy in the
places that are safe.

## `strip_sql_comments.py` — shrink a migration for a size-limited transport

```bash
python3 scripts/verification/strip_sql_comments.py in.sql [out.sql]
```

Removes `--` comments without touching string literals or dollar-quoted bodies. Used to put a
migration into a single `execute_query` call. It preserves one sentence of meaning per line
removed only by accident — always re-parse the output before running it anywhere.

## `extract.py` — pull one object out of a migration file

```bash
python3 scripts/verification/extract.py <file.sql> "create or replace function public.foo"
```

**Why the terminator matters:** a plpgsql body ends `end $$;`, with no newline before the
`$$`. Searching for a newline-preceded `$$;` runs straight past the object and returns the
next one too, which produced a false "this function is fine" reading exactly once. The whole
point of this helper is to make that mistake hard to repeat.
<<<<<<< ours
=======

## `insert_column_check.py` — does a test's INSERT actually name columns that exist?

```bash
python3 scripts/verification/insert_column_check.py supabase/tests/*.sql
```

Compares every `insert into <table> (<cols>)` against
`docs/insurance-brokerage/schema-columns.snapshot.json`.

**Why:** a committed end-to-end test inserted `currency` into `ins_commission_entries`, a
column that has never existed in the baseline or in any migration, and separately created a
bound policy with `status = 'active'` while leaving `bound_at` null and
`net_premium_to_insurer` unset, violating `ins_policies_bound_check`. Both would have
failed at the file's own fixture, before a single control was exercised. Neither is visible
to a parser: PostgreSQL resolves identifiers in an INSERT column list only when the
statement runs.

**Read a clean run narrowly.** It proves there are no column-name typos. It cannot see a
NOT NULL column you forgot to supply, a CHECK you violate, or a trigger that refuses the row
— and all three occur in the same file this was written for.
>>>>>>> theirs

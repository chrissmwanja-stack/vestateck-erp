-- Fails (non-empty result) if any BASE TABLE with a tenant_id column
-- lacks a real foreign-key constraint on it. Run in CI against a fresh
-- migration replay (see foundation-checks.yml) so a table added without
-- proper tenant isolation is caught before merge, not after -- this is
-- exactly the class of gap the 20260815063702 backfill (53 tables) had
-- to fix after the fact.
--
-- NOTE: must filter to table_type = 'BASE TABLE'. Views (v_trial_balance,
-- petty_cash_float_balances, etc) also expose a tenant_id column but
-- can't hold constraints -- an unfiltered version of this query
-- permanently flags ~10 views as false positives. Verified clean
-- (0 rows) against production on 2026-08-18 with this filter in place.
select c.table_name
from information_schema.columns c
join information_schema.tables t
  on t.table_schema = c.table_schema
  and t.table_name = c.table_name
  and t.table_type = 'BASE TABLE'
where c.column_name = 'tenant_id'
  and c.table_schema = 'public'
except
select tc.table_name
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu using (constraint_name)
where tc.constraint_type = 'FOREIGN KEY'
  and kcu.column_name = 'tenant_id';
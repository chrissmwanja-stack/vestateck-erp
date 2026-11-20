-- =====================================================================
-- Drop the unused renamed bind-snapshot function
-- =====================================================================
-- 20261120005000 renamed the original ins_snapshot_bind_config() to
-- ins_snapshot_bind_config_commission_only() so a wrapper could call it. A trigger
-- function cannot be called from another function, so 20261120235903 rewrote
-- ins_snapshot_bind_config() as the single function holding both responsibilities
-- and left the renamed copy behind, unused.
--
-- Left behind, it is a trigger function with no trigger attached, which the
-- "Static plpgsql lint (plpgsql_check)" CI step cannot check (a trigger function
-- must be checked against a trigger's table; with none, plpgsql_check raises
-- "missing trigger relation" and the whole step fails).
--
-- Nothing references it any more: the only callers were the superseded wrapper
-- bodies in 20261120005000 / 235900 / 235901, all replaced by 20261120235903.
-- Dropping a function is not a data change (no table or column is touched), and
-- MIGRATION_POLICY rule 8 covers DROP COLUMN / DROP TABLE only.
drop function if exists public.ins_snapshot_bind_config_commission_only();

select 'unused bind snapshot commission_only function dropped' as status;

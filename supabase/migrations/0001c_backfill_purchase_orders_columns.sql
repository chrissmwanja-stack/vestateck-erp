-- 0001c_backfill_purchase_orders_columns.sql
--
-- purchase_orders.shared_with_supplier / delivered_at / completed_at exist
-- on the live database but were never created by any migration in git --
-- they were added directly via the Supabase Studio table editor before
-- migration tracking caught up, same root cause as
-- 20260808052808_backfill_pretracking_objects.sql. 0002_approval_queue_rpc.sql
-- reads shared_with_supplier and would fail on a fresh replay without this.
--
-- Idempotent (IF NOT EXISTS) -- safe no-op against the existing live database.

alter table purchase_orders
  add column if not exists shared_with_supplier boolean not null default false,
  add column if not exists delivered_at timestamptz,
  add column if not exists completed_at timestamptz;
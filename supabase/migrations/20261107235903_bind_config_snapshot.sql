-- =====================================================================
-- Stage 3: connect accounting configuration to posting.
-- When a policy becomes active (bound), snapshot the commission
-- recognition treatment in force into ins_policies.accounting_config_snapshot,
-- so every later recognition/reversal can be traced to the config that
-- was in force at bind (transaction-level snapshot, per the design).
-- =====================================================================

alter table public.ins_policies
  add column if not exists accounting_config_snapshot jsonb;

create or replace function public.ins_snapshot_bind_config()
returns trigger language plpgsql security definer set search_path = 'public'
as $$
begin
  if new.status = 'active' and old.status is distinct from new.status then
    new.accounting_config_snapshot := jsonb_build_object(
      'ins.commission_recognition', public.acct_get_setting('ins.commission_recognition', new.inception_date),
      'resolved_at', now()
    );
  end if;
  return new;
end $$;

drop trigger if exists ins_bind_config_snapshot on public.ins_policies;
create trigger ins_bind_config_snapshot
  before update on public.ins_policies
  for each row execute function public.ins_snapshot_bind_config();

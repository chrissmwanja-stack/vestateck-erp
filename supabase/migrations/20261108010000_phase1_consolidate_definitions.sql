-- =====================================================================
-- Phase 1 — stabilise the accounting configuration framework.
--
-- 1. One namespace: the acct.* keys (migrated from the retired
--    tenant_accounting_config registry) duplicate the canonical ins.* /
--    migration.* keys. Values are mapped across, then acct.* keys and
--    their settings rows are removed.
-- 2. implemented flag: allowed_values may list FUTURE options, but only
--    values marked implemented are offered as selectable in the UI;
--    planned values are shown greyed out.
-- 3. Conflicting defaults resolved to the implemented treatment.
-- =====================================================================

alter table public.accounting_setting_definitions
  add column if not exists implemented_values text[] not null default '{}';

-- canonical keys: only the actually-implemented values are selectable
update public.accounting_setting_definitions
set implemented_values = allowed_values
where key in ('ins.commission_recognition', 'ins.cancellation_treatment',
              'migration.earned_commission_treatment', 'migration.partially_paid_import');

-- commission_recognition: only on_insurer_settlement is implemented today
update public.accounting_setting_definitions
set implemented_values = array['on_insurer_settlement'],
    allowed_values = array['on_insurer_settlement','at_placement','on_premium_collection','over_policy_term']
where key = 'ins.commission_recognition';

-- map acct.* values onto the canonical keys, then delete the duplicates
insert into public.company_accounting_settings
  (tenant_id, setting_key, value, effective_from, rationale, status,
   review_status, review_reference, reviewed_by, reviewed_at,
   created_by, created_at, approved_by, approved_at)
select c.tenant_id,
       case c.setting_key
         when 'acct.agent_commission_taxable' then 'ins.agent_commission_taxable'
         when 'acct.agent_commission_wht' then 'ins.agent_commission_wht'
         when 'acct.agent_commission_basis' then 'ins.agent_commission_basis'
         when 'acct.insurer_remittance_basis' then 'ins.insurer_remittance_basis'
         when 'acct.broker_fee_vat' then 'ins.broker_fee_vat'
         when 'acct.commission_earning' then 'ins.commission_earning'
         when 'acct.migration_earned_commission' then 'migration.earned_commission_treatment'
         when 'acct.migration_partially_paid' then 'migration.partially_paid_import'
         else c.setting_key end,
       c.value, c.effective_from,
       'migrated from ' || c.setting_key || ': ' || left(c.rationale, 180),
       c.status, c.review_status, c.review_reference, c.reviewed_by, c.reviewed_at,
       c.created_by, c.created_at, c.approved_by, c.approved_at
from public.company_accounting_settings c
where c.setting_key like 'acct.%'
  and c.status = 'approved'
on conflict do nothing;

delete from public.company_accounting_settings where setting_key like 'acct.%';
delete from public.accounting_setting_definitions where key like 'acct.%';

-- acct_assert_reviewed: pin search_path (hardening) and keep anon/public locked out
create or replace function public.acct_assert_reviewed(p_key text, p_on date default current_date)
returns text
language plpgsql stable security definer set search_path = pg_catalog, public
as $$
declare
  v_legal boolean;
  v_row public.company_accounting_settings;
begin
  select d.requires_legal_review into v_legal
  from public.accounting_setting_definitions d where d.key = p_key;
  if not found then
    raise exception 'ACCT_UNKNOWN_KEY: %', p_key;
  end if;
  if not coalesce(v_legal, false) then
    return public.acct_get_setting(p_key, p_on);
  end if;

  select * into v_row from public.company_accounting_settings s
  where s.tenant_id = public.get_my_tenant_id() and s.setting_key = p_key
    and s.status = 'approved' and s.effective_from <= p_on
  order by s.effective_from desc limit 1;

  if not found then
    raise exception 'ACCT_LEGAL_UNREVIEWED: % has no approved value in force; configure and review it first', p_key;
  end if;
  if v_row.review_status <> 'reviewed' then
    raise exception 'ACCT_LEGAL_UNREVIEWED: % is approved but not compliance-reviewed', p_key;
  end if;
  return v_row.value;
end $$;

revoke all on function public.acct_assert_reviewed(text, date) from public, anon;
grant execute on function public.acct_assert_reviewed(text, date) to authenticated;

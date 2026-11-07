-- =====================================================================
-- Consolidation: fold tenant_accounting_config (20261107235900) into
-- company_accounting_settings (20261107150000). One config system.
--
-- Data migration:
--   * enum definitions  -> accounting_setting_definitions (allowed_values
--     from options, default = first option)
--   * approved config rows -> company_accounting_settings rows
--     (status approved; compliance unreviewed -> review_status unreviewed,
--      reviewed/approved -> reviewed with the stored review_reference)
-- Then the old tables and RPCs are dropped.
-- =====================================================================

-- 1. Definitions (enum keys only; free-form json keys are not portable to
--    the text[] catalogue and stay documented in code).
insert into public.accounting_setting_definitions
  (key, label, description, allowed_values, default_value, requires_legal_review)
select
  'acct.' || d.key,
  d.name,
  coalesce(d.consequence_note, d.category),
  array(select jsonb_array_elements_text(coalesce(d.options, '[]'::jsonb))),
  (select jsonb_array_elements_text(coalesce(d.options, '[]'::jsonb)) limit 1),
  d.requires_legal_review
from public.accounting_config_definitions d
where d.value_type = 'enum'
  and jsonb_array_length(coalesce(d.options, '[]'::jsonb)) >= 1
on conflict (key) do nothing;

-- 2. Values: approved rows become approved settings.
insert into public.company_accounting_settings
  (tenant_id, setting_key, value, effective_from, rationale,
   status, review_status, reviewer_name, review_reference, reviewed_by, reviewed_at,
   created_by, created_at, approved_by, approved_at)
select
  c.tenant_id,
  'acct.' || c.key,
  c.value->>'value',
  c.effective_from,
  coalesce(e.note, 'migrated from tenant_accounting_config'),
  'approved',
  case when c.compliance_status = 'unreviewed' then 'unreviewed' else 'reviewed' end,
  case when c.compliance_status = 'unreviewed' then null else 'migrated reviewer' end,
  c.review_reference,
  c.reviewed_by,
  case when c.compliance_status = 'unreviewed' then null else c.updated_at end,
  c.created_by,
  c.created_at,
  c.approved_by,
  case when c.status = 'approved' then c.updated_at end
from public.tenant_accounting_config c
left join lateral (
  select note from public.tenant_accounting_config_events ev
  where ev.config_id = c.id and ev.event = 'created'
  order by ev.created_at limit 1
) e on true
where c.status = 'approved'
  and c.value ? 'value'
on conflict do nothing;

-- 3. Drop the old registry (tables, guard, RPCs).
drop trigger if exists tenant_accounting_config_guard on public.tenant_accounting_config;
drop function if exists public.tenant_accounting_config_guard();
drop function if exists public.acct_set_config(text, jsonb, date, text);
drop function if exists public.acct_approve_config(uuid);
drop function if exists public.acct_review_config(uuid, text, text);
drop function if exists public.acct_resolve(text, date);
drop table if exists public.tenant_accounting_config_events;
drop table if exists public.tenant_accounting_config;
drop table if exists public.accounting_config_definitions;

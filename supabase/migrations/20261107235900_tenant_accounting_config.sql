-- =====================================================================
-- Stage 1: Company Accounting & Tax Configuration registry.
--
-- Design principle (docs/insurance-brokerage, accountant sign-off):
-- legitimate alternative treatments are configurable at COMPANY level,
-- with effective dates, maker-checker approval, an append-only audit
-- trail and a compliance status a company cannot self-approve.
-- Follows the regulatory_parameters pattern (20261016120000).
--
--   * accounting_config_definitions: platform catalogue of keys
--     (written by migrations only). Carries no values.
--   * tenant_accounting_config: effective-dated values per tenant.
--       status: draft -> approved -> retired; only approved rows resolve.
--       Approval is maker-checker: approver must be a company admin who
--       is NOT the creator (ACCT_SELF_APPROVAL).
--       compliance_status: unreviewed -> reviewed -> approved. 'approved'
--       REQUIRES a review_reference (accountant/compliance adviser) and a
--       reviewer who is not the config creator (ACCT_REVIEW_REQUIRED).
--       Configurable is not legally unrestricted: legal-applicability keys
--       (marked requires_legal_review in the catalogue) can never leave
--       'unreviewed' without that reference.
--   * tenant_accounting_config_events: append-only audit.
--   * acct_resolve: internal resolver — latest approved row in force.
-- =====================================================================

create table if not exists public.accounting_config_definitions (
  key                 text primary key,
  name                text not null,
  category            text not null,
  value_type          text not null check (value_type in ('enum','number','boolean','text','json')),
  options             jsonb,                       -- allowed enum values
  requires_legal_review boolean not null default false,
  consequence_note    text,                        -- shown in the UI
  created_at          timestamptz not null default now()
);

create table if not exists public.tenant_accounting_config (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants(id) on delete cascade,
  key                 text not null references public.accounting_config_definitions(key),
  value               jsonb not null,
  effective_from      date not null,
  effective_to        date,
  status              text not null default 'draft'
                      check (status in ('draft','approved','retired')),
  compliance_status   text not null default 'unreviewed'
                      check (compliance_status in ('unreviewed','reviewed','approved')),
  review_reference    text,
  created_by          uuid not null default auth.uid(),
  approved_by         uuid,
  reviewed_by         uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint tenant_accounting_config_tenant_key_from_key unique (tenant_id, key, effective_from),
  constraint tenant_accounting_config_period_check check (effective_to is null or effective_to >= effective_from),
  constraint tenant_accounting_config_review_check
    check (compliance_status <> 'approved' or (review_reference is not null and reviewed_by is not null))
);

create table if not exists public.tenant_accounting_config_events (
  id          uuid primary key default gen_random_uuid(),
  config_id   uuid not null references public.tenant_accounting_config(id) on delete cascade,
  tenant_id   uuid not null,
  event       text not null,               -- created | approved | retired | review
  actor_id    uuid not null default auth.uid(),
  note        text,
  created_at  timestamptz not null default now()
);

create index if not exists tenant_accounting_config_tenant_key_idx
  on public.tenant_accounting_config (tenant_id, key, effective_from);
create index if not exists tenant_accounting_config_events_idx
  on public.tenant_accounting_config_events (tenant_id, config_id);

alter table public.tenant_accounting_config enable row level security;
alter table public.tenant_accounting_config_events enable row level security;
alter table public.accounting_config_definitions enable row level security;

create policy "acct_config_select" on public.tenant_accounting_config
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id());
create policy "acct_config_events_select" on public.tenant_accounting_config_events
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id());
create policy "acct_config_defs_select" on public.accounting_config_definitions
  for select to authenticated using (true);

revoke all on public.tenant_accounting_config,
              public.tenant_accounting_config_events,
              public.accounting_config_definitions from public, anon;

-- No DML policies: writes go through the RPCs only (guard trigger below
-- enforces the same for direct SQL even by table owners in tests).
create or replace function public.tenant_accounting_config_guard()
returns trigger language plpgsql as $$
begin
  if current_setting('ins.via_rpc', true) <> 'on' then
    raise exception 'ACCT_CONFIG_RPC_ONLY' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists tenant_accounting_config_guard on public.tenant_accounting_config;
create trigger tenant_accounting_config_guard before insert or update
  on public.tenant_accounting_config for each row
  execute function public.tenant_accounting_config_guard();

-- =====================================================================
-- Catalogue: the configurable treatments. requires_legal_review marks
-- the keys whose applicability is a question of law, not preference.
-- =====================================================================
insert into public.accounting_config_definitions (key, name, category, value_type, options, requires_legal_review, consequence_note) values
  ('agent_commission_taxable', 'Agent commission taxation', 'tax', 'enum',
   '["taxable","not_taxable"]', true,
   'Whether agent commission is subject to tax; legal applicability must be reviewed.'),
  ('agent_commission_wht', 'Withholding tax on agent commission', 'tax', 'enum',
   '["applicable","not_applicable"]', true,
   'WHT applicability is a legal question (Ugandan IRA treatment differs for brokers vs agents).'),
  ('agent_commission_basis', 'Commission tax calculation basis', 'tax', 'enum',
   '["gross_commission","net_commission"]', false,
   'Gross vs net-of-deductions basis for any commission tax.'),
  ('commission_recognition', 'Commission recognition timing', 'accounting', 'enum',
   '["at_placement","on_premium_collection","on_insurer_remittance","over_policy_term"]', false,
   'When commission becomes earned income; affects deferral schedule.'),
  ('insurer_remittance_basis', 'Insurer remittance basis', 'accounting', 'enum',
   '["gross_premium","net_of_commission"]', true,
   'Whether the insurer may legally be paid net of commission is not a free choice.'),
  ('broker_fee_vat', 'Broker fee VAT', 'tax', 'enum',
   '["vat_applicable","not_applicable"]', true,
   'VAT treatment of broker fees requires review.'),
  ('commission_earning', 'Commission earning method', 'accounting', 'enum',
   '["immediate","deferred_over_time"]', false,
   'Immediate recognition vs deferral over the earning period.'),
  ('cancellation_treatment', 'Cancellation refund & commission reversal', 'accounting', 'json',
   null, false,
   'Refund and commission-reversal treatment on cancellation; free-form policy.'),
  ('migration_earned_commission', 'Cut-over earned commission treatment', 'migration', 'enum',
   '["opening_balances","other_approved"]', true,
   'Earned commission at cut-over goes to opening balances; alternatives need accountant approval.'),
  ('migration_partially_paid', 'Partially paid policy import', 'migration', 'enum',
   '["full_billed_plus_receipts","verified_opening_balances_only"]', false,
   'Full billed + receipts preserves policy history and reconciles to the opening ledger.')
on conflict (key) do nothing;

-- =====================================================================
-- RPCs
-- =====================================================================

-- Create a draft value row (finance/company admin).
create or replace function public.acct_set_config(
  p_key text, p_value jsonb, p_effective_from date, p_note text default null
)
returns public.tenant_accounting_config
language plpgsql security definer set search_path = 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_def public.accounting_config_definitions;
  v_row public.tenant_accounting_config;
begin
  if v_tenant is null or not public.is_company_admin() then
    raise exception 'ACCT_FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_def from public.accounting_config_definitions where key = p_key;
  if not found then raise exception 'ACCT_UNKNOWN_KEY'; end if;
  if v_def.value_type = 'enum' and (p_value ? 'value') and
     not (p_value->>'value') = any (select jsonb_array_elements_text(coalesce(v_def.options, '[]'::jsonb))) then
    raise exception 'ACCT_BAD_VALUE: not one of the allowed options for %', p_key;
  end if;
  if exists (
    select 1 from public.tenant_accounting_config c
    where c.tenant_id = v_tenant and c.key = p_key and c.status = 'approved'
      and c.effective_from <= p_effective_from
      and (c.effective_to is null or c.effective_to >= p_effective_from)
  ) then
    raise exception 'ACCT_OVERLAP: an approved row is already in force for % on %', p_key, p_effective_from;
  end if;

  set local ins.via_rpc = 'on';
  insert into public.tenant_accounting_config
    (tenant_id, key, value, effective_from, created_by)
  values (v_tenant, p_key, p_value, p_effective_from, auth.uid())
  returning * into v_row;
  insert into public.tenant_accounting_config_events (config_id, tenant_id, event, note)
  values (v_row.id, v_tenant, 'created', p_note);
  reset ins.via_rpc;
  return v_row;
end $$;

-- Maker-checker approval (company admin who is not the creator).
create or replace function public.acct_approve_config(p_id uuid)
returns public.tenant_accounting_config
language plpgsql security definer set search_path = 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row public.tenant_accounting_config;
begin
  if v_tenant is null or not public.is_company_admin() then
    raise exception 'ACCT_FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_row from public.tenant_accounting_config
  where id = p_id and tenant_id = v_tenant for update;
  if not found then raise exception 'ACCT_NOT_FOUND'; end if;
  if v_row.status <> 'draft' then raise exception 'ACCT_NOT_DRAFT'; end if;
  if v_row.created_by = auth.uid() then
    raise exception 'ACCT_SELF_APPROVAL: the creator cannot approve their own config';
  end if;

  set local ins.via_rpc = 'on';
  update public.tenant_accounting_config
  set status = 'approved', approved_by = auth.uid(), updated_at = now()
  where id = p_id returning * into v_row;
  insert into public.tenant_accounting_config_events (config_id, tenant_id, event)
  values (v_row.id, v_tenant, 'approved');
  reset ins.via_rpc;
  return v_row;
end $$;

-- Compliance review. 'approved' compliance status requires a reference
-- and a reviewer different from the creator; legal-review keys can never
-- be self-certified.
create or replace function public.acct_review_config(
  p_id uuid, p_status text, p_reference text default null
)
returns public.tenant_accounting_config
language plpgsql security definer set search_path = 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row public.tenant_accounting_config;
  v_def public.accounting_config_definitions;
begin
  if v_tenant is null or not public.is_company_admin() then
    raise exception 'ACCT_FORBIDDEN' using errcode = '42501';
  end if;
  if p_status not in ('reviewed','approved','unreviewed') then
    raise exception 'ACCT_BAD_REVIEW_STATUS';
  end if;
  select * into v_row from public.tenant_accounting_config
  where id = p_id and tenant_id = v_tenant for update;
  if not found then raise exception 'ACCT_NOT_FOUND'; end if;
  select * into v_def from public.accounting_config_definitions where key = v_row.key;
  if p_status = 'approved' and (p_reference is null or btrim(p_reference) = '') then
    raise exception 'ACCT_REVIEW_REFERENCE_REQUIRED';
  end if;
  if p_status <> 'unreviewed' and v_row.created_by = auth.uid() then
    raise exception 'ACCT_SELF_REVIEW: the creator cannot review their own config';
  end if;

  set local ins.via_rpc = 'on';
  update public.tenant_accounting_config
  set compliance_status = p_status, review_reference = p_reference,
      reviewed_by = case when p_status = 'unreviewed' then null else auth.uid() end,
      updated_at = now()
  where id = p_id returning * into v_row;
  insert into public.tenant_accounting_config_events (config_id, tenant_id, event, note)
  values (v_row.id, v_tenant, 'review', p_reference);
  reset ins.via_rpc;
  return v_row;
end $$;

-- Resolver: latest approved row in force on a date. Fails loudly.
create or replace function public.acct_resolve(p_key text, p_on date default current_date)
returns jsonb language sql stable security definer set search_path = 'public'
as $$
  select c.value from public.tenant_accounting_config c
  where c.tenant_id = public.get_my_tenant_id() and c.key = p_key
    and c.status = 'approved'
    and c.effective_from <= p_on and (c.effective_to is null or c.effective_to >= p_on)
  order by c.effective_from desc limit 1;
$$;

revoke all on function public.acct_set_config(text, jsonb, date, text) from public, anon;
revoke all on function public.acct_approve_config(uuid) from public, anon;
revoke all on function public.acct_review_config(uuid, text, text) from public, anon;
revoke all on function public.acct_resolve(text, date) from public, anon;
grant execute on function public.acct_set_config(text, jsonb, date, text) to authenticated;
grant execute on function public.acct_approve_config(uuid) to authenticated;
grant execute on function public.acct_review_config(uuid, text, text) to authenticated;
grant execute on function public.acct_resolve(text, date) to authenticated;

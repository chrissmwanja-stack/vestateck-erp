-- =====================================================================
-- Insurance brokerage, slice Q1: quotation pipeline
--
-- Quotes (one insurer per quote; placement = the set of quotes for a
-- risk) with a server-side state machine:
--   draft -> submitted -> accepted | declined
--   accepted -> placed (a draft ins_policy is created from the quote)
--
-- Working rules honoured: writes go through RPCs only (no DML policies,
-- table revoked from public/anon), tenant RLS on reads, quote numbers
-- from next_doc_number, every RPC is SECURITY DEFINER with tenant and
-- access checks and refuses cross-tenant callers.
-- =====================================================================

create table if not exists public.ins_quotes (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants(id) on delete cascade,
  quote_no            text not null,
  client_id           uuid not null,
  insurer_id          uuid not null,
  product_line_id     uuid not null,
  status              text not null default 'draft',
  sum_insured         numeric(18,2) not null default 0,
  currency            text not null default 'UGX',
  gross_premium       numeric(18,2) not null default 0,
  commission_rate_pct numeric(5,2) not null default 0,
  valid_until         date,
  submitted_at        timestamptz,
  submitted_by        uuid,
  insurer_ref         text,
  decided_at          timestamptz,
  decided_by          uuid,
  accepted_policy_id  uuid,
  notes               text,
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint ins_quotes_tenant_id_id_key unique (tenant_id, id),
  constraint ins_quotes_tenant_quote_no_key unique (tenant_id, quote_no),
  constraint ins_quotes_tenant_client_fk foreign key (tenant_id, client_id)
    references public.ins_clients (tenant_id, id) on delete restrict,
  constraint ins_quotes_tenant_insurer_fk foreign key (tenant_id, insurer_id)
    references public.ins_insurers (tenant_id, id) on delete restrict,
  constraint ins_quotes_tenant_product_fk foreign key (tenant_id, product_line_id)
    references public.ins_product_lines (tenant_id, id) on delete restrict,
  constraint ins_quotes_tenant_policy_fk foreign key (tenant_id, accepted_policy_id)
    references public.ins_policies (tenant_id, id) on delete restrict,
  constraint ins_quotes_status_check check (status in ('draft','submitted','accepted','declined','placed')),
  constraint ins_quotes_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint ins_quotes_sum_check check (sum_insured >= 0),
  constraint ins_quotes_premium_check check (gross_premium >= 0),
  constraint ins_quotes_commission_check check (commission_rate_pct >= 0 and commission_rate_pct < 100),
  constraint ins_quotes_placed_check check (
    (status = 'placed' and accepted_policy_id is not null)
    or (status <> 'placed' and accepted_policy_id is null)
  ),
  constraint ins_quotes_submitted_check check (
    (status in ('submitted','accepted','declined','placed') and submitted_at is not null)
    or status = 'draft'
  )
);

create index if not exists ins_quotes_tenant_status_idx on public.ins_quotes (tenant_id, status);
create index if not exists ins_quotes_client_idx on public.ins_quotes (client_id);
create index if not exists ins_quotes_insurer_idx on public.ins_quotes (insurer_id);

-- Quote numbering, same trigger shape as the other modules.
create or replace function public.set_ins_quote_defaults()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.quote_no is null or new.quote_no = '' then
    new.quote_no := public.next_doc_number(new.tenant_id, 'ins_quote', 'Q-');
  end if;
  new.tenant_id := public.get_my_tenant_id();
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.set_ins_quote_defaults() from public, anon, authenticated, service_role;

drop trigger if exists trg_set_ins_quote_defaults on public.ins_quotes;
create trigger trg_set_ins_quote_defaults
  before insert or update on public.ins_quotes
  for each row execute function public.set_ins_quote_defaults();

alter table public.ins_quotes enable row level security;

create policy "ins_quotes_select" on public.ins_quotes
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

-- No insert/update/delete policies on purpose: writes go through the RPCs
-- below only.
revoke all on public.ins_quotes from public, anon;

-- =====================================================================
-- RPCs
-- =====================================================================

create or replace function public.ins_create_quote(
  p_client_id uuid,
  p_insurer_id uuid,
  p_product_line_id uuid,
  p_sum_insured numeric,
  p_currency text,
  p_gross_premium numeric,
  p_commission_rate_pct numeric,
  p_valid_until date default null,
  p_notes text default null
)
returns public.ins_quotes
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_quote public.ins_quotes;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  -- Referenced rows must exist in the caller's own tenant.
  if not exists (select 1 from public.ins_clients c where c.tenant_id = v_tenant and c.id = p_client_id) then
    raise exception 'INS_CLIENT_NOT_FOUND';
  end if;
  if not exists (select 1 from public.ins_insurers i where i.tenant_id = v_tenant and i.id = p_insurer_id and i.is_active) then
    raise exception 'INS_INSURER_NOT_FOUND_OR_INACTIVE';
  end if;
  if not exists (select 1 from public.ins_product_lines pl where pl.tenant_id = v_tenant and pl.id = p_product_line_id and pl.is_active) then
    raise exception 'INS_PRODUCT_LINE_NOT_FOUND_OR_INACTIVE';
  end if;

  set local ins.via_rpc = 'on';
  insert into public.ins_quotes (
    tenant_id, client_id, insurer_id, product_line_id, status,
    sum_insured, currency, gross_premium, commission_rate_pct,
    valid_until, notes, created_by
  ) values (
    v_tenant, p_client_id, p_insurer_id, p_product_line_id, 'draft',
    p_sum_insured, upper(p_currency), p_gross_premium, p_commission_rate_pct,
    p_valid_until, p_notes, auth.uid()
  )
  returning * into v_quote;
  reset ins.via_rpc;

  return v_quote;
end;
$$;

revoke all on function public.ins_create_quote(uuid, uuid, uuid, numeric, text, numeric, numeric, date, text) from public, anon;
grant execute on function public.ins_create_quote(uuid, uuid, uuid, numeric, text, numeric, numeric, date, text) to authenticated;

-- draft -> submitted
create or replace function public.ins_submit_quote(p_quote_id uuid)
returns public.ins_quotes
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_quote public.ins_quotes;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_quote from public.ins_quotes
  where tenant_id = v_tenant and id = p_quote_id;
  if v_quote.id is null then
    raise exception 'INS_QUOTE_NOT_FOUND';
  end if;
  if v_quote.status <> 'draft' then
    raise exception 'INS_QUOTE_NOT_DRAFT';
  end if;
  if v_quote.valid_until is not null and v_quote.valid_until < current_date then
    raise exception 'INS_QUOTE_EXPIRED';
  end if;

  set local ins.via_rpc = 'on';
  update public.ins_quotes
  set status = 'submitted', submitted_at = now(), submitted_by = auth.uid(), updated_at = now()
  where tenant_id = v_tenant and id = p_quote_id
  returning * into v_quote;
  reset ins.via_rpc;

  return v_quote;
end;
$$;

revoke all on function public.ins_submit_quote(uuid) from public, anon;
grant execute on function public.ins_submit_quote(uuid) to authenticated;

-- submitted -> accepted | declined (manager tier)
create or replace function public.ins_decide_quote(
  p_quote_id uuid,
  p_decision text,
  p_insurer_ref text default null
)
returns public.ins_quotes
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_quote public.ins_quotes;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_decision not in ('accepted', 'declined') then
    raise exception 'INS_QUOTE_BAD_DECISION';
  end if;

  select * into v_quote from public.ins_quotes
  where tenant_id = v_tenant and id = p_quote_id;
  if v_quote.id is null then
    raise exception 'INS_QUOTE_NOT_FOUND';
  end if;
  if v_quote.status <> 'submitted' then
    raise exception 'INS_QUOTE_NOT_SUBMITTED';
  end if;

  set local ins.via_rpc = 'on';
  update public.ins_quotes
  set status = p_decision,
      insurer_ref = coalesce(p_insurer_ref, insurer_ref),
      decided_at = now(),
      decided_by = auth.uid(),
      updated_at = now()
  where tenant_id = v_tenant and id = p_quote_id
  returning * into v_quote;
  reset ins.via_rpc;

  return v_quote;
end;
$$;

revoke all on function public.ins_decide_quote(uuid, text, text) from public, anon;
grant execute on function public.ins_decide_quote(uuid, text, text) to authenticated;

-- accepted -> placed: create a draft policy carrying the quote's terms.
create or replace function public.ins_place_quote(p_quote_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_quote public.ins_quotes;
  v_policy public.ins_policies;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_quote from public.ins_quotes
  where tenant_id = v_tenant and id = p_quote_id;
  if v_quote.id is null then
    raise exception 'INS_QUOTE_NOT_FOUND';
  end if;
  if v_quote.status <> 'accepted' then
    raise exception 'INS_QUOTE_NOT_ACCEPTED';
  end if;

  set local ins.via_rpc = 'on';
  insert into public.ins_policies (
    tenant_id, client_id, insurer_id, product_line_id, status,
    inception_date, expiry_date,
    sum_insured, currency, gross_premium, commission_rate_pct,
    notes, created_by
  ) values (
    v_tenant, v_quote.client_id, v_quote.insurer_id, v_quote.product_line_id, 'draft',
    current_date, current_date + interval '1 year',
    v_quote.sum_insured, v_quote.currency, v_quote.gross_premium, v_quote.commission_rate_pct,
    v_quote.notes, auth.uid()
  )
  returning * into v_policy;

  update public.ins_quotes
  set status = 'placed', accepted_policy_id = v_policy.id, updated_at = now()
  where tenant_id = v_tenant and id = p_quote_id;
  reset ins.via_rpc;

  return v_policy;
end;
$$;

revoke all on function public.ins_place_quote(uuid) from public, anon;
grant execute on function public.ins_place_quote(uuid) to authenticated;

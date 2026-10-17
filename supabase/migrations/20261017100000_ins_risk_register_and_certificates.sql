-- Insured-risk register and motor certificate stock (roadmap gap 1).
--
--   ins_risks             the insured object: a vehicle, property or other risk
--                         belonging to one client. Any product line.
--   ins_policy_risks      which risks a draft policy covers.
--   ins_certificate_stock serial-numbered certificate stock. A certificate moves
--                         in_stock -> issued (to a vehicle risk, optionally
--                         attached to a draft policy) -> used (at bind), or is
--                         spoiled or voided.
--
-- Every write goes through a security definer RPC. The tables have select-only
-- RLS for authenticated users. Binding a policy in the MOTOR product line now
-- requires an issued motor certificate attached to that policy.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.ins_risks (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  client_id        uuid not null references public.ins_clients(id) on delete restrict,
  product_line_id  uuid not null references public.ins_product_lines(id) on delete restrict,
  risk_type        text not null,
  description      text not null,
  reg_no           text,
  chassis_no       text,
  engine_no        text,
  make             text,
  model            text,
  year_made        integer,
  sum_insured      numeric(18,2) not null default 0,
  status           text not null default 'active',
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint ins_risks_tenant_id_id_key unique (tenant_id, id),
  constraint ins_risks_chassis_key unique (tenant_id, chassis_no),
  constraint ins_risks_type_check check (risk_type in ('vehicle', 'property', 'other')),
  constraint ins_risks_status_check check (status in ('active', 'inactive')),
  constraint ins_risks_description_check check (length(btrim(description)) > 0),
  constraint ins_risks_sum_check check (sum_insured >= 0),
  constraint ins_risks_year_check check (year_made is null or year_made between 1950 and 2100)
);

create table if not exists public.ins_policy_risks (
  tenant_id   uuid not null,
  policy_id   uuid not null,
  risk_id     uuid not null,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  primary key (policy_id, risk_id),
  constraint ins_policy_risks_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies(tenant_id, id) on delete cascade,
  constraint ins_policy_risks_risk_fk foreign key (tenant_id, risk_id)
    references public.ins_risks(tenant_id, id) on delete restrict
);

create table if not exists public.ins_certificate_stock (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  serial_no    text not null,
  status       text not null default 'in_stock',
  issued_to    text,
  risk_id      uuid,
  policy_id    uuid,
  issued_at    timestamptz,
  closed_at    timestamptz,
  close_reason text,
  loaded_by    uuid default auth.uid(),
  loaded_at    timestamptz not null default now(),
  constraint ins_certificate_stock_tenant_serial_key unique (tenant_id, serial_no),
  constraint ins_certificate_stock_status_check check (status in ('in_stock', 'issued', 'used', 'spoiled', 'voided')),
  constraint ins_certificate_stock_serial_check check (length(btrim(serial_no)) > 0),
  constraint ins_certificate_stock_stock_check check (status <> 'in_stock' or (risk_id is null and policy_id is null)),
  constraint ins_certificate_stock_used_check check (status <> 'used' or policy_id is not null),
  constraint ins_certificate_stock_attach_check check (policy_id is null or status in ('issued', 'used')),
  constraint ins_certificate_stock_risk_fk foreign key (tenant_id, risk_id)
    references public.ins_risks(tenant_id, id) on delete restrict,
  constraint ins_certificate_stock_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies(tenant_id, id) on delete restrict
);

create index if not exists ins_risks_client_idx on public.ins_risks (tenant_id, client_id);
create index if not exists ins_certificate_stock_policy_idx on public.ins_certificate_stock (tenant_id, policy_id);

drop trigger if exists ins_risks_touch_trg on public.ins_risks;
create trigger ins_risks_touch_trg before update on public.ins_risks
  for each row execute function public.ins_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Row-level security: read only for authenticated insurance users
-- ---------------------------------------------------------------------------
alter table public.ins_risks             enable row level security;
alter table public.ins_policy_risks      enable row level security;
alter table public.ins_certificate_stock enable row level security;

revoke insert, update, delete on public.ins_risks, public.ins_policy_risks, public.ins_certificate_stock
  from public, anon, authenticated;
grant select on public.ins_risks, public.ins_policy_risks, public.ins_certificate_stock to authenticated;

drop policy if exists ins_risks_select on public.ins_risks;
create policy ins_risks_select on public.ins_risks
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());

drop policy if exists ins_policy_risks_select on public.ins_policy_risks;
create policy ins_policy_risks_select on public.ins_policy_risks
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());

drop policy if exists ins_certificate_stock_select on public.ins_certificate_stock;
create policy ins_certificate_stock_select on public.ins_certificate_stock
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());

-- ---------------------------------------------------------------------------
-- 3. RPCs (writes)
-- ---------------------------------------------------------------------------

-- Register an insured risk for a client. A MOTOR risk must be a vehicle with a
-- chassis number, because certificates and the register are matched on it.
create or replace function public.ins_register_risk(
  p_client_id uuid,
  p_product_line_id uuid,
  p_risk_type text,
  p_description text,
  p_reg_no text default null,
  p_chassis_no text default null,
  p_engine_no text default null,
  p_make text default null,
  p_model text default null,
  p_year_made integer default null,
  p_sum_insured numeric default 0
) returns uuid
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare t uuid := get_my_tenant_id(); line_code text; new_id uuid;
begin
  if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode = '42501'; end if;
  if not exists (select 1 from ins_clients where id = p_client_id and tenant_id = t) then raise exception 'INS_NOT_FOUND: client'; end if;
  select code into line_code from ins_product_lines where id = p_product_line_id and tenant_id = t and is_active;
  if not found then raise exception 'INS_NOT_FOUND: active product line'; end if;
  if line_code = 'MOTOR' and p_risk_type <> 'vehicle' then
    raise exception 'INS_RISK_TYPE: a motor product line needs a vehicle risk';
  end if;
  if line_code = 'MOTOR' and nullif(btrim(coalesce(p_chassis_no, '')), '') is null then
    raise exception 'INS_RISK_INPUT: a vehicle needs a chassis number';
  end if;
  begin
    insert into ins_risks (tenant_id, client_id, product_line_id, risk_type, description, reg_no, chassis_no, engine_no,
      make, model, year_made, sum_insured)
    values (t, p_client_id, p_product_line_id, p_risk_type, btrim(p_description),
      nullif(btrim(coalesce(p_reg_no, '')), ''), nullif(btrim(coalesce(p_chassis_no, '')), ''),
      nullif(btrim(coalesce(p_engine_no, '')), ''), nullif(btrim(coalesce(p_make, '')), ''),
      nullif(btrim(coalesce(p_model, '')), ''), p_year_made, coalesce(p_sum_insured, 0))
    returning id into new_id;
  exception when unique_violation then
    raise exception 'INS_DUPLICATE: a risk with this chassis number already exists';
  end;
  return new_id;
end $$;
revoke all on function public.ins_register_risk(uuid, uuid, text, text, text, text, text, text, text, integer, numeric) from public, anon;
grant execute on function public.ins_register_risk(uuid, uuid, text, text, text, text, text, text, text, integer, numeric) to authenticated;

-- Make the register inactive or active again. An inactive risk cannot be newly
-- linked to a policy or receive a certificate.
create or replace function public.ins_set_risk_status(p_risk_id uuid, p_status text)
returns void language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
begin
  if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode = '42501'; end if;
  if p_status not in ('active', 'inactive') then raise exception 'INS_INPUT: status must be active or inactive'; end if;
  update ins_risks set status = p_status where id = p_risk_id and tenant_id = get_my_tenant_id();
  if not found then raise exception 'INS_NOT_FOUND: risk'; end if;
end $$;
revoke all on function public.ins_set_risk_status(uuid, text) from public, anon;
grant execute on function public.ins_set_risk_status(uuid, text) to authenticated;

-- Load a serial range into stock. Any duplicate serial fails the whole load, so
-- a range never loads with silent gaps.
create or replace function public.ins_load_certificate_range(
  p_prefix text,
  p_from bigint,
  p_to bigint,
  p_width integer default 8
) returns integer
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare t uuid := get_my_tenant_id(); n integer;
begin
  if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_from < 0 or p_to < p_from then raise exception 'INS_INPUT: the range must start at 0 or more and end at or after its start'; end if;
  if p_to - p_from >= 5000 then raise exception 'INS_INPUT: load at most 5000 certificates at a time'; end if;
  if p_width is null or p_width < 1 or p_width > 20 then raise exception 'INS_INPUT: serial width must be 1 to 20'; end if;
  begin
    with gen as (
      select coalesce(btrim(p_prefix), '') || lpad(g::text, p_width, '0') as serial
      from generate_series(p_from, p_to) g
    )
    insert into ins_certificate_stock (tenant_id, serial_no)
    select t, serial from gen;
  exception when unique_violation then
    raise exception 'INS_DUPLICATE: some serials in this range are already in stock';
  end;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.ins_load_certificate_range(text, bigint, bigint, integer) from public, anon;
grant execute on function public.ins_load_certificate_range(text, bigint, bigint, integer) to authenticated;

-- Issue one in-stock certificate to a vehicle risk.
create or replace function public.ins_issue_certificate(p_serial_no text, p_risk_id uuid, p_issued_to text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare t uuid := get_my_tenant_id(); c ins_certificate_stock%rowtype;
begin
  if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode = '42501'; end if;
  select * into c from ins_certificate_stock where tenant_id = t and serial_no = btrim(p_serial_no) for update;
  if not found then raise exception 'INS_NOT_FOUND: certificate'; end if;
  if c.status <> 'in_stock' then raise exception 'INS_CERTIFICATE_STATE: certificate % is %, not in stock', c.serial_no, c.status; end if;
  if not exists (select 1 from ins_risks where id = p_risk_id and tenant_id = t and status = 'active' and risk_type = 'vehicle') then
    raise exception 'INS_CERTIFICATE_RISK: certificates are issued to an active vehicle risk';
  end if;
  update ins_certificate_stock
     set status = 'issued', risk_id = p_risk_id, issued_to = nullif(btrim(coalesce(p_issued_to, '')), ''), issued_at = now()
   where id = c.id;
  return c.id;
end $$;
revoke all on function public.ins_issue_certificate(text, uuid, text) from public, anon;
grant execute on function public.ins_issue_certificate(text, uuid, text) to authenticated;

-- Spoil or void a certificate that is not used and not attached to a policy.
create or replace function public.ins_void_certificate(p_serial_no text, p_status text, p_reason text)
returns void
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare t uuid := get_my_tenant_id(); c ins_certificate_stock%rowtype;
begin
  if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode = '42501'; end if;
  if p_status not in ('spoiled', 'voided') then raise exception 'INS_INPUT: status must be spoiled or voided'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'INS_INPUT: a reason is required'; end if;
  select * into c from ins_certificate_stock where tenant_id = t and serial_no = btrim(p_serial_no) for update;
  if not found then raise exception 'INS_NOT_FOUND: certificate'; end if;
  if c.status not in ('in_stock', 'issued') or c.policy_id is not null then
    raise exception 'INS_CERTIFICATE_STATE: only a certificate in stock or issued and not attached to a policy can be closed';
  end if;
  update ins_certificate_stock set status = p_status, closed_at = now(), close_reason = btrim(p_reason) where id = c.id;
end $$;
revoke all on function public.ins_void_certificate(text, text, text) from public, anon;
grant execute on function public.ins_void_certificate(text, text, text) to authenticated;

-- Link a risk to a draft policy. The risk must belong to the policy's client.
create or replace function public.ins_link_policy_risk(p_policy_id uuid, p_risk_id uuid)
returns void
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare t uuid := get_my_tenant_id(); p ins_policies%rowtype;
begin
  if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode = '42501'; end if;
  select * into p from ins_policies where id = p_policy_id and tenant_id = t for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if p.status <> 'draft' then raise exception 'INS_NOT_DRAFT: risks can only be linked to a draft policy'; end if;
  if not exists (select 1 from ins_risks r where r.id = p_risk_id and r.tenant_id = t and r.client_id = p.client_id and r.status = 'active') then
    raise exception 'INS_RISK_CLIENT: an active risk of this policy''s client is required';
  end if;
  insert into ins_policy_risks (tenant_id, policy_id, risk_id) values (t, p_policy_id, p_risk_id)
  on conflict (policy_id, risk_id) do nothing;
end $$;
revoke all on function public.ins_link_policy_risk(uuid, uuid) from public, anon;
grant execute on function public.ins_link_policy_risk(uuid, uuid) to authenticated;

-- Remove a risk from a draft policy and release any certificate attached for it.
create or replace function public.ins_unlink_policy_risk(p_policy_id uuid, p_risk_id uuid)
returns void
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare t uuid := get_my_tenant_id(); st text;
begin
  if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode = '42501'; end if;
  select status into st from ins_policies where id = p_policy_id and tenant_id = t for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if st <> 'draft' then raise exception 'INS_NOT_DRAFT: risks can only be unlinked from a draft policy'; end if;
  update ins_certificate_stock set policy_id = null
   where tenant_id = t and policy_id = p_policy_id and risk_id = p_risk_id and status = 'issued';
  delete from ins_policy_risks where tenant_id = t and policy_id = p_policy_id and risk_id = p_risk_id;
end $$;
revoke all on function public.ins_unlink_policy_risk(uuid, uuid) from public, anon;
grant execute on function public.ins_unlink_policy_risk(uuid, uuid) to authenticated;

-- Attach an issued certificate to a draft policy. The certificate's risk must
-- already be linked to that policy. One certificate per policy: a certificate
-- already attached to it is released first.
create or replace function public.ins_attach_certificate(p_policy_id uuid, p_serial_no text)
returns void
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare t uuid := get_my_tenant_id(); p ins_policies%rowtype; c ins_certificate_stock%rowtype;
begin
  if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode = '42501'; end if;
  select * into p from ins_policies where id = p_policy_id and tenant_id = t for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if p.status <> 'draft' then raise exception 'INS_NOT_DRAFT: certificates can only be attached to a draft policy'; end if;
  select * into c from ins_certificate_stock where tenant_id = t and serial_no = btrim(p_serial_no) for update;
  if not found then raise exception 'INS_NOT_FOUND: certificate'; end if;
  if c.status <> 'issued' or c.policy_id is not null then
    raise exception 'INS_CERTIFICATE_STATE: certificate % must be issued and not attached to another policy', c.serial_no;
  end if;
  if not exists (select 1 from ins_policy_risks where policy_id = p_policy_id and risk_id = c.risk_id) then
    raise exception 'INS_CERTIFICATE_RISK: link the certificate''s risk to this policy first';
  end if;
  update ins_certificate_stock set policy_id = null
   where tenant_id = t and policy_id = p_policy_id and status = 'issued';
  update ins_certificate_stock set policy_id = p_policy_id where id = c.id;
end $$;
revoke all on function public.ins_attach_certificate(uuid, text) from public, anon;
grant execute on function public.ins_attach_certificate(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Motor gate on bind
--
-- The existing bind (co-insurance version) is kept under a new name. The new
-- wrapper runs it first, so permission, tenant, draft and financial checks all
-- still apply, then requires an attached issued certificate for a MOTOR policy.
-- Any failure rolls back the whole bind, journal included.
-- ---------------------------------------------------------------------------
alter function public.ins_bind_policy(uuid) rename to platform_ins_bind_policy_risk_legacy_impl;
revoke all on function public.platform_ins_bind_policy_risk_legacy_impl(uuid) from public, anon, authenticated;

create function public.ins_bind_policy(p_policy_id uuid) returns public.ins_policies
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare p ins_policies%rowtype; is_motor boolean;
begin
  p := platform_ins_bind_policy_risk_legacy_impl(p_policy_id);
  select exists (select 1 from ins_product_lines l where l.id = p.product_line_id and l.code = 'MOTOR') into is_motor;
  if is_motor then
    if not exists (select 1 from ins_certificate_stock c where c.tenant_id = p.tenant_id and c.policy_id = p.id and c.status = 'issued') then
      raise exception 'INS_MOTOR_CERTIFICATE_REQUIRED: attach an issued motor certificate to this policy before binding';
    end if;
    update ins_certificate_stock set status = 'used' where tenant_id = p.tenant_id and policy_id = p.id and status = 'issued';
  end if;
  return p;
end $$;
revoke all on function public.ins_bind_policy(uuid) from public, anon;
grant execute on function public.ins_bind_policy(uuid) to authenticated;

-- Replace the earlier free-text prf_oif_number with a server-generated
-- value: {organization.company_code}-UG-{6-digit sequence}, e.g.
-- UGN-UG-000728, confirmed against the MAKS reference tool. PRF and OIF
-- are the same value under two names, not two separate fields.
--
-- Requires organization_id to be set (it supplies the company_code), so
-- Organization moves from optional to required on both invoice tables.
-- Both tables currently have 0 rows, so no backfill is needed.

drop index if exists public.supplier_invoices_prf_oif_number_idx;
drop index if exists public.receivable_invoices_prf_oif_number_idx;

alter table public.supplier_invoices
  alter column organization_id set not null;

alter table public.receivable_invoices
  alter column organization_id set not null;

-- One counter per organization per invoice type -- Supplier and
-- Receivable invoices number independently, per Chris's call.
create table public.oif_sequences (
  organization_id uuid not null references public.organizations(id),
  invoice_type text not null check (invoice_type in ('supplier', 'receivable')),
  last_number integer not null default 0,
  primary key (organization_id, invoice_type)
);

alter table public.oif_sequences enable row level security;

create policy "finance team can view oif sequences"
  on public.oif_sequences for select
  using (public.is_finance_team_member());

-- Trigger functions assign the number once, on insert only -- editing an
-- invoice's organization afterward does not renumber it, since a reference
-- number that changes underneath an already-issued invoice would be more
-- confusing than a stale org label. Revisit if that's not the desired
-- behavior.
create or replace function public.assign_supplier_invoice_oif()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_code text;
  v_next_number integer;
begin
  select company_code into v_company_code
  from public.organizations
  where id = new.organization_id;

  if v_company_code is null then
    raise exception 'organization % has no company_code', new.organization_id;
  end if;

  insert into public.oif_sequences (organization_id, invoice_type, last_number)
  values (new.organization_id, 'supplier', 1)
  on conflict (organization_id, invoice_type)
  do update set last_number = public.oif_sequences.last_number + 1
  returning last_number into v_next_number;

  new.prf_oif_number := v_company_code || '-UG-' || lpad(v_next_number::text, 6, '0');
  return new;
end;
$$;

create or replace function public.assign_receivable_invoice_oif()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_code text;
  v_next_number integer;
begin
  select company_code into v_company_code
  from public.organizations
  where id = new.organization_id;

  if v_company_code is null then
    raise exception 'organization % has no company_code', new.organization_id;
  end if;

  insert into public.oif_sequences (organization_id, invoice_type, last_number)
  values (new.organization_id, 'receivable', 1)
  on conflict (organization_id, invoice_type)
  do update set last_number = public.oif_sequences.last_number + 1
  returning last_number into v_next_number;

  new.prf_oif_number := v_company_code || '-UG-' || lpad(v_next_number::text, 6, '0');
  return new;
end;
$$;

drop trigger if exists set_supplier_invoice_oif on public.supplier_invoices;
create trigger set_supplier_invoice_oif
  before insert on public.supplier_invoices
  for each row
  execute function public.assign_supplier_invoice_oif();

drop trigger if exists set_receivable_invoice_oif on public.receivable_invoices;
create trigger set_receivable_invoice_oif
  before insert on public.receivable_invoices
  for each row
  execute function public.assign_receivable_invoice_oif();

alter table public.supplier_invoices
  alter column prf_oif_number set not null;
alter table public.receivable_invoices
  alter column prf_oif_number set not null;

create unique index supplier_invoices_prf_oif_number_key
  on public.supplier_invoices (prf_oif_number);
create unique index receivable_invoices_prf_oif_number_key
  on public.receivable_invoices (prf_oif_number);

-- ============================================================
-- Shared infrastructure for HR / Legal / BD / IT modules
-- Run this FIRST, before the four module files.
-- ============================================================

create extension if not exists "pgcrypto";

-- ------------------------------------------------------------
-- 1. Module-level roles
-- ------------------------------------------------------------
create table if not exists public.staff_roles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  user_id uuid not null references public.app_users(id) on delete cascade,
  module text not null check (module in ('hr','legal','bd','it')),
  role text not null check (role in ('admin','manager','member')),
  created_at timestamptz not null default now(),
  unique (tenant_id, user_id, module)
);

alter table public.staff_roles enable row level security;

create index if not exists idx_staff_roles_tenant on public.staff_roles(tenant_id);
create index if not exists idx_staff_roles_user on public.staff_roles(user_id);

create policy "tenant_read_staff_roles" on public.staff_roles
  for select using (tenant_id = public.get_my_tenant_id());

create policy "platform_admin_write_staff_roles" on public.staff_roles
  for all using (
    tenant_id = public.get_my_tenant_id()
    and exists (select 1 from public.app_users where id = auth.uid() and is_platform_admin)
  );

-- ------------------------------------------------------------
-- 2. has_module_role()
-- ------------------------------------------------------------
create or replace function public.has_module_role(p_module text, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    exists (
      select 1 from public.app_users
      where id = auth.uid() and is_platform_admin
    )
    or exists (
      select 1 from public.staff_roles
      where user_id = auth.uid()
        and module = p_module
        and role = any(p_roles)
        and tenant_id = public.get_my_tenant_id()
    );
$$;

-- ------------------------------------------------------------
-- 3. Atomic document numbering
-- ------------------------------------------------------------
create table if not exists public.doc_sequences (
  tenant_id uuid not null,
  doc_type text not null,
  year text not null,
  last_number int not null default 0,
  primary key (tenant_id, doc_type, year)
);

create or replace function public.next_doc_number(
  p_tenant_id uuid,
  p_doc_type text,
  p_prefix text,
  p_pad int default 4
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  yr text := to_char(now(), 'YYYY');
  n int;
begin
  insert into public.doc_sequences (tenant_id, doc_type, year, last_number)
  values (p_tenant_id, p_doc_type, yr, 1)
  on conflict (tenant_id, doc_type, year)
  do update set last_number = public.doc_sequences.last_number + 1
  returning last_number into n;

  return p_prefix || '-' || yr || '-' || lpad(n::text, p_pad, '0');
end;
$$;

-- ------------------------------------------------------------
-- 4. Generic updated_at trigger
-- ------------------------------------------------------------
create or replace function public.handle_updated_at_generic()
returns trigger
language plpgsql
as $$
begin
  NEW.updated_at = now();
  return NEW;
end;
$$;

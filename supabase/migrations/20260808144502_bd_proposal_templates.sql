create table public.bd_proposal_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  name text not null,
  description text,
  content text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, name)
);

alter table public.bd_proposal_templates enable row level security;

create policy "bd_proposal_templates_select" on public.bd_proposal_templates
  for select using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());
create policy "bd_proposal_templates_write" on public.bd_proposal_templates
  for all using (tenant_id = public.get_my_tenant_id() and public.is_business_dev());

create trigger trg_bd_proposal_templates_upd before update on public.bd_proposal_templates
  for each row execute function public.handle_updated_at_generic();
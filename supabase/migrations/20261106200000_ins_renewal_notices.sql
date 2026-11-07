-- =====================================================================
-- Insurance brokerage, slice B1: renewal notices
--
-- One notice per renewing policy (the notice references the expiring
-- policy; the renewal draft it points to is the pipeline row).
--   draft -> sent
-- Bulk generation is idempotent: ins_generate_renewal_notices() creates
-- a draft notice for every active/renewed policy expiring within the
-- 120-day window that has no notice yet. Writes go through RPCs only.
-- =====================================================================

create table if not exists public.ins_renewal_notices (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  notice_no  text not null,
  policy_id  uuid not null,   -- the expiring (source) policy
  status     text not null default 'draft'
             check (status in ('draft', 'sent')),
  channel    text not null default 'email'
             check (channel in ('email', 'portal', 'print')),
  sent_at    timestamptz,
  sent_by    uuid,
  notes      text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ins_renewal_notices_tenant_id_id_key unique (tenant_id, id),
  constraint ins_renewal_notices_tenant_notice_no_key unique (tenant_id, notice_no),
  constraint ins_renewal_notices_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies (tenant_id, id) on delete cascade,
  constraint ins_renewal_notices_one_per_policy unique (tenant_id, policy_id),
  constraint ins_renewal_notices_sent_check check (
    (status = 'sent' and sent_at is not null)
    or (status = 'draft' and sent_at is null and sent_by is null)
  )
);

create index if not exists ins_renewal_notices_tenant_status_idx
  on public.ins_renewal_notices (tenant_id, status);

create or replace function public.set_ins_renewal_notice_defaults()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.notice_no is null or new.notice_no = '' then
    new.notice_no := public.next_doc_number(new.tenant_id, 'ins_renewal_notice', 'N-');
  end if;
  new.tenant_id := public.get_my_tenant_id();
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function public.set_ins_renewal_notice_defaults() from public, anon, authenticated, service_role;

drop trigger if exists trg_set_ins_renewal_notice_defaults on public.ins_renewal_notices;
create trigger trg_set_ins_renewal_notice_defaults
  before insert or update on public.ins_renewal_notices
  for each row execute function public.set_ins_renewal_notice_defaults();

alter table public.ins_renewal_notices enable row level security;

create policy "ins_renewal_notices_select" on public.ins_renewal_notices
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

revoke all on public.ins_renewal_notices from public, anon;

-- =====================================================================
-- RPCs
-- =====================================================================

-- Bulk, idempotent: draft notice for each active/renewed policy expiring
-- within 120 days that has none yet. Returns the created notice ids.
create or replace function public.ins_generate_renewal_notices()
returns table (notice_id uuid, policy_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  p record;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  for p in
    select ip.id as pid
      from public.ins_policies ip
     where ip.tenant_id = v_tenant
       and ip.status in ('active', 'renewed')
       and ip.expiry_date <= current_date + 120
       and not exists (
         select 1 from public.ins_renewal_notices n
         where n.tenant_id = v_tenant and n.policy_id = ip.id
       )
  loop
    set local ins.via_rpc = 'on';
    insert into public.ins_renewal_notices (tenant_id, policy_id, created_by)
    values (v_tenant, p.pid, auth.uid())
    returning id into notice_id;
    reset ins.via_rpc;
    policy_id := p.pid;
    return next;
  end loop;
end;
$$;

revoke all on function public.ins_generate_renewal_notices() from public, anon;
grant execute on function public.ins_generate_renewal_notices() to authenticated;

-- draft -> sent (manager tier)
create or replace function public.ins_mark_renewal_notice_sent(
  p_notice_id uuid,
  p_channel text default 'email'
)
returns public.ins_renewal_notices
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_n public.ins_renewal_notices;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_channel not in ('email', 'portal', 'print') then
    raise exception 'INS_NOTICE_BAD_CHANNEL';
  end if;

  select * into v_n from public.ins_renewal_notices
  where tenant_id = v_tenant and id = p_notice_id;
  if v_n.id is null then raise exception 'INS_NOTICE_NOT_FOUND'; end if;
  if v_n.status <> 'draft' then raise exception 'INS_NOTICE_NOT_DRAFT'; end if;

  set local ins.via_rpc = 'on';
  update public.ins_renewal_notices
  set status = 'sent', sent_at = now(), sent_by = auth.uid(), channel = p_channel, updated_at = now()
  where tenant_id = v_tenant and id = p_notice_id
  returning * into v_n;
  reset ins.via_rpc;

  return v_n;
end;
$$;

revoke all on function public.ins_mark_renewal_notice_sent(uuid, text) from public, anon;
grant execute on function public.ins_mark_renewal_notice_sent(uuid, text) to authenticated;

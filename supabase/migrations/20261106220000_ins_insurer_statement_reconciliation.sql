-- =====================================================================
-- Insurance brokerage, slice S1: insurer statement reconciliation
--
-- An insurer statement (header + per-policy lines as the insurer reports
-- them) is recorded, then reconciled line-by-line against the brokerage's
-- own records: premium vs ins_policies.gross_premium, claims vs
-- ins_claims.paid_amount, commission vs ins_commission_entries.
-- Read-only reconciliation RPC returns match/mismatch per line.
-- Writes through RPCs only; reads RLS-scoped to insurance access.
-- =====================================================================

create table if not exists public.ins_insurer_statements (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  insurer_id    uuid not null,
  statement_ref text not null,               -- the insurer's own reference
  period_from   date not null,
  period_to     date not null,
  received_date date not null default current_date,
  status        text not null default 'received'
                check (status in ('received', 'reconciled', 'disputed')),
  notes         text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  constraint ins_insurer_statements_tenant_id_id_key unique (tenant_id, id),
  constraint ins_insurer_statements_tenant_ref_key unique (tenant_id, insurer_id, statement_ref),
  constraint ins_insurer_statements_insurer_fk foreign key (tenant_id, insurer_id)
    references public.ins_insurers (tenant_id, id) on delete restrict,
  constraint ins_insurer_statements_period_check check (period_to >= period_from)
);

create table if not exists public.ins_insurer_statement_lines (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  statement_id uuid not null,
  policy_id    uuid not null,
  premium      numeric(18,2) not null default 0,
  commission   numeric(18,2) not null default 0,
  claims_paid  numeric(18,2) not null default 0,
  constraint ins_insurer_statement_lines_tenant_id_id_key unique (tenant_id, id),
  constraint ins_insurer_statement_lines_stmt_fk foreign key (tenant_id, statement_id)
    references public.ins_insurer_statements (tenant_id, id) on delete cascade,
  constraint ins_insurer_statement_lines_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies (tenant_id, id) on delete restrict,
  constraint ins_insurer_statement_lines_one_per_policy unique (tenant_id, statement_id, policy_id)
);

create index if not exists ins_insurer_statement_lines_stmt_idx
  on public.ins_insurer_statement_lines (tenant_id, statement_id);

alter table public.ins_insurer_statements enable row level security;
alter table public.ins_insurer_statement_lines enable row level security;

create policy "ins_insurer_statements_select" on public.ins_insurer_statements
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());
create policy "ins_insurer_statement_lines_select" on public.ins_insurer_statement_lines
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

revoke all on public.ins_insurer_statements, public.ins_insurer_statement_lines from public, anon;

-- =====================================================================
-- RPCs
-- =====================================================================

-- Record a statement with its lines in one call. Lines: jsonb array of
-- {policy_id, premium, commission, claims_paid}.
create or replace function public.ins_record_insurer_statement(
  p_insurer_id uuid,
  p_statement_ref text,
  p_period_from date,
  p_period_to date,
  p_lines jsonb,
  p_notes text default null
)
returns public.ins_insurer_statements
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_stmt public.ins_insurer_statements;
  l jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.ins_insurers i
    where i.tenant_id = v_tenant and i.id = p_insurer_id
  ) then
    raise exception 'INS_INSURER_NOT_FOUND';
  end if;
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then
    raise exception 'INS_STATEMENT_NO_LINES';
  end if;

  set local ins.via_rpc = 'on';
  insert into public.ins_insurer_statements
    (tenant_id, insurer_id, statement_ref, period_from, period_to, notes, created_by)
  values
    (v_tenant, p_insurer_id, p_statement_ref, p_period_from, p_period_to, p_notes, auth.uid())
  returning * into v_stmt;

  for l in select * from jsonb_array_elements(p_lines)
  loop
    -- every line's policy must belong to this tenant
    if not exists (
      select 1 from public.ins_policies p
      where p.tenant_id = v_tenant and p.id = (l->>'policy_id')::uuid
    ) then
      raise exception 'INS_STATEMENT_FOREIGN_POLICY';
    end if;
    insert into public.ins_insurer_statement_lines
      (tenant_id, statement_id, policy_id, premium, commission, claims_paid)
    values (
      v_tenant, v_stmt.id, (l->>'policy_id')::uuid,
      coalesce((l->>'premium')::numeric, 0),
      coalesce((l->>'commission')::numeric, 0),
      coalesce((l->>'claims_paid')::numeric, 0)
    );
  end loop;
  reset ins.via_rpc;

  return v_stmt;
end;
$$;

revoke all on function public.ins_record_insurer_statement(uuid, text, date, date, jsonb, text) from public, anon;
grant execute on function public.ins_record_insurer_statement(uuid, text, date, date, jsonb, text) to authenticated;

-- Reconcile: per line, compare the insurer's figures with our records.
create or replace function public.ins_insurer_statement_reconciliation(p_statement_id uuid)
returns table (
  line_id uuid,
  policy_id uuid,
  policy_no text,
  field text,
  insurer_amount numeric,
  our_amount numeric,
  match boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  l record;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.ins_insurer_statements s
    where s.tenant_id = v_tenant and s.id = p_statement_id
  ) then
    raise exception 'INS_STATEMENT_NOT_FOUND';
  end if;

  for l in
    select sl.id as lid, sl.policy_id as pid, p.policy_no,
           sl.premium, sl.commission, sl.claims_paid,
           p.gross_premium,
           coalesce((select sum(e.amount) from public.ins_commission_entries e
                     where e.tenant_id = v_tenant and e.policy_id = sl.policy_id), 0) as our_commission,
           coalesce((select sum(c.paid_amount) from public.ins_claims c
                     where c.tenant_id = v_tenant and c.policy_id = sl.policy_id), 0) as our_claims
      from public.ins_insurer_statement_lines sl
      join public.ins_policies p on p.tenant_id = sl.tenant_id and p.id = sl.policy_id
     where sl.tenant_id = v_tenant and sl.statement_id = p_statement_id
  loop
    line_id := l.lid; policy_id := l.pid; policy_no := l.policy_no;
    field := 'premium';
    insurer_amount := l.premium; our_amount := l.gross_premium;
    match := (l.premium = l.gross_premium); return next;
    field := 'commission';
    insurer_amount := l.commission; our_amount := l.our_commission;
    match := (l.commission = l.our_commission); return next;
    field := 'claims_paid';
    insurer_amount := l.claims_paid; our_amount := l.our_claims;
    match := (l.claims_paid = l.our_claims); return next;
  end loop;
end;
$$;

revoke all on function public.ins_insurer_statement_reconciliation(uuid) from public, anon;
grant execute on function public.ins_insurer_statement_reconciliation(uuid) to authenticated;

-- Mark the statement reconciled/disputed (manager tier).
create or replace function public.ins_decide_insurer_statement(
  p_statement_id uuid,
  p_status text,
  p_notes text default null
)
returns public.ins_insurer_statements
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_stmt public.ins_insurer_statements;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_status not in ('reconciled', 'disputed') then
    raise exception 'INS_STATEMENT_BAD_STATUS';
  end if;

  select * into v_stmt from public.ins_insurer_statements
  where tenant_id = v_tenant and id = p_statement_id;
  if v_stmt.id is null then raise exception 'INS_STATEMENT_NOT_FOUND'; end if;

  set local ins.via_rpc = 'on';
  update public.ins_insurer_statements
  set status = p_status, notes = coalesce(p_notes, notes)
  where tenant_id = v_tenant and id = p_statement_id
  returning * into v_stmt;
  reset ins.via_rpc;

  return v_stmt;
end;
$$;

revoke all on function public.ins_decide_insurer_statement(uuid, text, text) from public, anon;
grant execute on function public.ins_decide_insurer_statement(uuid, text, text) to authenticated;

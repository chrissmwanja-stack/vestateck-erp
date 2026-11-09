-- Workstream B: period close. accounting_periods per tenant, and a
-- guard inside post_journal_entry() (the single choke point every
-- journal entry -- auto-posted or manual -- passes through) that
-- refuses to post into a closed period. Because the three
-- auto-posting triggers call post_journal_entry() inside the same
-- transaction as the subledger insert, a closed-period rejection
-- rolls back the whole insert -- so this also blocks new supplier
-- invoices, receivable invoices, and cash/bank transactions dated
-- into a closed period, not just raw journal entries. That's the
-- "and by extension the subledger RPCs" behavior from the original
-- plan, gotten for free from where the guard already had to live.

create table if not exists public.accounting_periods (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    period_start date not null,
    period_end date not null,
    status text not null default 'open',
    closed_at timestamp with time zone,
    closed_by uuid,
    created_at timestamp with time zone not null default now(),
    constraint accounting_periods_status_check check (status in ('open', 'closed')),
    constraint accounting_periods_range_check check (period_end >= period_start),
    constraint accounting_periods_tenant_range_unique unique (tenant_id, period_start, period_end)
);

comment on table public.accounting_periods is
    'Per-tenant accounting periods. A closed period blocks new journal '
    'entries (and therefore new supplier/receivable invoices and '
    'cash/bank transactions) dated inside it -- see post_journal_entry().';

create index if not exists accounting_periods_tenant_idx
    on public.accounting_periods (tenant_id, period_start);

-- Two periods for the same tenant must not cover overlapping dates --
-- otherwise "is this date closed" is ambiguous. No btree_gist
-- extension dependency: a small deferred constraint trigger over the
-- handful of periods a tenant has is simpler than adding an
-- extension for one exclusion constraint.
create or replace function public.check_accounting_period_no_overlap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from accounting_periods
    where tenant_id = new.tenant_id
      and id != new.id
      and period_start <= new.period_end
      and period_end >= new.period_start
  ) then
    raise exception 'accounting period % to % overlaps an existing period for this tenant', new.period_start, new.period_end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_check_accounting_period_no_overlap on public.accounting_periods;
create trigger trg_check_accounting_period_no_overlap
    before insert or update of period_start, period_end on public.accounting_periods
    for each row
    execute function public.check_accounting_period_no_overlap();

-- Stamp closed_at/closed_by on the transition to closed, and clear
-- them on reopen, so that's never left for the client to set (and
-- potentially get wrong or spoof) directly.
create or replace function public.stamp_accounting_period_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'closed' and old.status = 'open' then
    new.closed_at := now();
    new.closed_by := auth.uid();
  elsif new.status = 'open' and old.status = 'closed' then
    new.closed_at := null;
    new.closed_by := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_stamp_accounting_period_close on public.accounting_periods;
create trigger trg_stamp_accounting_period_close
    before update of status on public.accounting_periods
    for each row
    execute function public.stamp_accounting_period_close();

alter table public.accounting_periods enable row level security;

create policy "accounting_periods_select" on public.accounting_periods
    for select using (is_finance_team_member(null::text) and tenant_id = get_my_tenant_id());
create policy "accounting_periods_insert" on public.accounting_periods
    for insert with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());
create policy "accounting_periods_update" on public.accounting_periods
    for update using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id())
    with check (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());
create policy "accounting_periods_delete" on public.accounting_periods
    for delete using (is_finance_team_member('finance'::text) and tenant_id = get_my_tenant_id());

grant select, insert, update, delete on public.accounting_periods to authenticated;

-- The guard itself: post_journal_entry() is the one function every
-- journal entry insert (auto-posted or, in future, manual) goes
-- through, so this is the only place the check needs to live.
create or replace function public.post_journal_entry(
    p_tenant_id uuid,
    p_source_type text,
    p_source_id uuid,
    p_entry_date date,
    p_description text,
    p_lines jsonb
)
returns public.journal_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry journal_entries%rowtype;
  v_line jsonb;
begin
  if exists (
    select 1 from accounting_periods
    where tenant_id = p_tenant_id
      and status = 'closed'
      and p_entry_date between period_start and period_end
  ) then
    raise exception 'cannot post to %: this date falls in a closed accounting period', p_entry_date;
  end if;

  insert into journal_entries (tenant_id, entry_date, source_type, source_id, description, posted_by)
  values (p_tenant_id, p_entry_date, p_source_type, p_source_id, p_description, auth.uid())
  returning * into v_entry;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    insert into journal_entry_lines (journal_entry_id, tenant_id, gl_account_id, debit, credit, description)
    values (
      v_entry.id,
      p_tenant_id,
      (v_line ->> 'gl_account_id')::uuid,
      coalesce((v_line ->> 'debit')::numeric, 0),
      coalesce((v_line ->> 'credit')::numeric, 0),
      v_line ->> 'description'
    );
  end loop;

  return v_entry;
end;
$$;
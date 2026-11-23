-- =====================================================================
-- Statutory charges: an allocation record around bind, and a traceable report
-- =====================================================================
--
-- Before this migration a policy's statutory charge lines (ins_policy_charges)
-- recorded the assessment and the amount, and nothing more. At bind the lines
-- were folded into each insurer share's pass_through_amount and into one
-- invoice total, so billing, payable recognition, collection and remittance
-- could not be traced to a charge.
--
-- Decisions (INSURANCE_DECISIONS_REGISTER, DR-47 to DR-50):
--   DR-47  Brokerage and insurer remittance are both supported, by charge type
--          and legal responsibility. The catalogue already records the
--          collector; a charge whose collector is the insurer is remitted to the
--          authority by the insurer, any other collector means the brokerage
--          holds and remits it.
--   DR-48  A partial receipt or remittance covers a charge pro rata, with an
--          auditable breakdown. Cents are allocated by largest remainder so the
--          parts always add up to the whole.
--   DR-49  Reversal on cancellation follows each charge's legal refundability.
--          Not built here; see "Not in this migration".
--   DR-50  Core bind posting is NOT changed. Detail is added around it.
--
-- What this adds
--   1. ins_policy_charge_allocations: one immutable row per charge and insurer
--      share, written by a trigger when a policy becomes active, and backfilled
--      for policies already bound. It splits every pass-through charge across
--      the insurer shares with the same cent rule bind uses, so the rows add up
--      to each share's recorded pass_through_amount. The report flags any policy
--      where they do not.
--   2. ins_report_statutory_charge_trace: the single source. One row per stage
--      (assessed, collected, remitted) per charge allocation, with the basis of
--      every pro rata split written out.
--   3. ins_report_statutory_charges: the summary, aggregated from the trace so
--      it cannot disagree with it.
--   4. ins_report_statutory_charge_exceptions: the reconciliation. Per policy,
--      allocations against the booked pass-through, and the bind journal's
--      credit to insurer payable against the shares' payable amounts.
--
-- Not in this migration (stated so nobody assumes it)
--   - Reversal or retention of a charge on cancellation or endorsement (DR-49).
--     It needs a refundability attribute on the catalogue and a change to the
--     cancellation posting; a cancelled policy keeps its allocation rows and the
--     report shows it as cancelled.
--   - Posting to the statutory payable accounts and a remittance to an
--     authority, for charges the brokerage collects itself (DR-47). No active
--     catalogue charge needs it today.
--   - Allocation of collections to premium and VAT components; only the charge
--     share is derived.
--
-- Dating: a charge belongs to the Kampala business day its policy was bound.
-- Collections and remittances are counted as at the end of the period (a
-- settlement voided after that date still counts), matching DR-38.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The allocation record
-- ---------------------------------------------------------------------
create table if not exists public.ins_policy_charge_allocations (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  policy_id        uuid not null references public.ins_policies(id) on delete cascade,
  charge_id        uuid not null references public.ins_policy_charges(id) on delete cascade,
  insurer_share_id uuid not null references public.ins_policy_insurer_shares(id) on delete cascade,
  insurer_id       uuid not null,
  amount           numeric(18,2) not null check (amount >= 0),
  currency         text not null,
  journal_entry_id uuid,
  source           text not null check (source in ('bind', 'backfill')),
  created_at       timestamptz not null default now(),
  unique (charge_id, insurer_share_id)
);

create index if not exists ins_policy_charge_allocations_policy_idx
  on public.ins_policy_charge_allocations (tenant_id, policy_id);
create index if not exists ins_policy_charge_allocations_share_idx
  on public.ins_policy_charge_allocations (insurer_share_id);

comment on table public.ins_policy_charge_allocations is
  'One row per pass-through charge and insurer share, written when the policy is bound (or backfilled). Immutable; written only by ins_record_charge_allocations.';

alter table public.ins_policy_charge_allocations enable row level security;

drop policy if exists ins_policy_charge_allocations_select on public.ins_policy_charge_allocations;
create policy ins_policy_charge_allocations_select on public.ins_policy_charge_allocations
  for select to authenticated using (
    tenant_id = get_my_tenant_id()
    and (can_access_insurance() or is_finance_team_member('finance'))
  );

-- Select only: no insert, update or delete policy, and the privileges are
-- withdrawn as well, so the table cannot be written by a caller at all.
revoke all on public.ins_policy_charge_allocations from public, anon, authenticated;
grant select on public.ins_policy_charge_allocations to authenticated;

create or replace function public.ins_policy_charge_allocations_immutable()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
begin
  raise exception 'INS_CHARGE_ALLOCATION_IMMUTABLE: charge allocations are evidence and cannot be changed or removed'
    using errcode = '42501';
end;
$$;

drop trigger if exists ins_policy_charge_allocations_immutable on public.ins_policy_charge_allocations;
create trigger ins_policy_charge_allocations_immutable
  before update on public.ins_policy_charge_allocations
  for each row execute function public.ins_policy_charge_allocations_immutable();
revoke all on function public.ins_policy_charge_allocations_immutable() from public, anon, authenticated;

select public.apply_tenant_read_only_guard();

-- ---------------------------------------------------------------------
-- 2. Splitting a policy's pass-through charges across its insurer shares
-- ---------------------------------------------------------------------
-- The cent rule is the one bind uses for an "all insurers" charge: each share
-- gets the amount times its percentage rounded down to the cent, and the
-- leftover cents go to the shares with the largest fractions, ties by insurer id.
-- A "one insurer" charge goes whole to that insurer's share.
create or replace function public.ins_charge_allocation_replay(p_policy_id uuid)
returns table (
  charge_id        uuid,
  insurer_share_id uuid,
  insurer_id       uuid,
  amount           numeric
)
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  with ch as (
    select c.id, c.amount, c.recipient_mode, c.recipient_insurer_id
      from public.ins_policy_charges c
     where c.policy_id = p_policy_id
       and c.kind = 'insurer_pass_through'
       and c.amount > 0
  ),
  one as (
    select ch.id as charge_id, s.id as share_id, s.insurer_id, ch.amount
      from ch
      join public.ins_policy_insurer_shares s
        on s.policy_id = p_policy_id and s.insurer_id = ch.recipient_insurer_id
     where ch.recipient_mode = 'one_insurer'
  ),
  parts as (
    select ch.id as charge_id, s.id as share_id, s.insurer_id,
           ch.amount,
           trunc(ch.amount * s.share_pct / 100, 2) as base,
           (ch.amount * s.share_pct / 100) - trunc(ch.amount * s.share_pct / 100, 2) as frac
      from ch
      join public.ins_policy_insurer_shares s on s.policy_id = p_policy_id
     where ch.recipient_mode is distinct from 'one_insurer'
  ),
  ranked as (
    select p.*,
           row_number() over (partition by p.charge_id order by p.frac desc, p.insurer_id) as rk,
           round((p.amount - sum(p.base) over (partition by p.charge_id)) * 100)::integer as cents
      from parts p
  )
  select o.charge_id, o.share_id, o.insurer_id, o.amount from one o
  union all
  select r.charge_id, r.share_id, r.insurer_id,
         r.base + case when r.rk <= r.cents then 0.01 else 0 end
    from ranked r
$$;
revoke all on function public.ins_charge_allocation_replay(uuid) from public, anon, authenticated;

create or replace function public.ins_record_charge_allocations(p_policy_id uuid, p_source text default 'bind')
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_pol public.ins_policies;
  v_n   integer;
begin
  select * into v_pol from public.ins_policies where id = p_policy_id;
  if not found then
    return 0;
  end if;
  if exists (select 1 from public.ins_policy_charge_allocations where policy_id = p_policy_id) then
    return 0;
  end if;

  insert into public.ins_policy_charge_allocations
    (tenant_id, policy_id, charge_id, insurer_share_id, insurer_id, amount, currency, journal_entry_id, source)
  select v_pol.tenant_id, p_policy_id, r.charge_id, r.insurer_share_id, r.insurer_id, r.amount,
         v_pol.currency, v_pol.journal_entry_id, p_source
    from public.ins_charge_allocation_replay(p_policy_id) r
   where r.amount > 0;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.ins_record_charge_allocations(uuid, text) from public, anon, authenticated;

create or replace function public.ins_policies_record_charge_allocations()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  perform public.ins_record_charge_allocations(new.id, 'bind');
  return new;
end;
$$;
revoke all on function public.ins_policies_record_charge_allocations() from public, anon, authenticated;

-- Fires after the bind's own UPDATE, so the shares' pass_through_amount is
-- already written, and adds a record around the posting without changing it.
drop trigger if exists ins_policies_record_charge_allocations on public.ins_policies;
create trigger ins_policies_record_charge_allocations
  after update of status on public.ins_policies
  for each row
  when (old.status is distinct from new.status
        and new.status = 'active'
        and new.journal_entry_id is not null)
  execute function public.ins_policies_record_charge_allocations();

-- Policies already bound before this migration.
do $$
declare
  r record;
begin
  for r in
    select p.id
      from public.ins_policies p
     where p.journal_entry_id is not null
       and exists (select 1 from public.ins_policy_charges c
                    where c.policy_id = p.id and c.kind = 'insurer_pass_through' and c.amount > 0)
       and not exists (select 1 from public.ins_policy_charge_allocations a where a.policy_id = p.id)
  loop
    perform public.ins_record_charge_allocations(r.id, 'backfill');
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. The trace: one row per stage per charge allocation
-- ---------------------------------------------------------------------
create or replace function public.ins_report_statutory_charge_trace(
  p_from            date,
  p_to              date,
  p_include_imported boolean default false,
  p_include_manual   boolean default false
)
returns table (
  stage          text,
  cohort_month   text,
  policy_id      uuid,
  policy_no      text,
  client_name    text,
  policy_status  text,
  insurer_id     uuid,
  insurer_name   text,
  charge_id      uuid,
  charge_code    text,
  charge_name    text,
  charge_class   text,
  collector      text,
  recipient_name text,
  payable_role   text,
  currency       text,
  event_date     date,
  settlement_id  uuid,
  settlement_no  text,
  amount         numeric,
  basis          text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if auth.uid() is null or not (public.can_access_insurance() or public.is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN: insurance or finance access is required' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'INS_REPORT_INPUT: a valid period is required';
  end if;

  return query
  with a as (
    select al.id as aid, al.policy_id, al.charge_id, al.insurer_share_id, al.insurer_id, al.amount,
           al.currency, p.policy_no, p.status as policy_status, p.client_id,
           public.ins_local_date(p.bound_at) as bound_date,
           coalesce(c.catalogue_snapshot ->> 'code', 'MANUAL') as charge_code,
           c.description as charge_name, c.charge_class, c.collector, c.recipient_name, c.payable_role
      from public.ins_policy_charge_allocations al
      join public.ins_policies p on p.id = al.policy_id and p.tenant_id = v_tenant
      join public.ins_policy_charges c on c.id = al.charge_id
     where al.tenant_id = v_tenant
       and p.bound_at is not null
       and public.ins_local_date(p.bound_at) between p_from and p_to
       and (p_include_imported or p.import_batch_id is null)
       and (p_include_manual or c.catalogue_id is not null)
  ),
  -- Collections: a receipt settles the policy's invoice open item as a whole; the
  -- charge share is the receipt times the allocation over the invoice total.
  coll as (
    select fa.id as fa_id, s.id as settlement_id, s.settlement_no, s.settlement_date,
           fa.amount as fa_amount, i.amount as base_amount, a.aid, a.amount as a_amount,
           fa.amount * a.amount / i.amount as exact
      from a
      join public.fin_open_items i
        on i.tenant_id = v_tenant and i.source_type = 'ins_policy_premium'
       and i.source_id = a.policy_id and i.control_role = 'ar_control' and i.amount > 0
      join public.fin_allocations fa on fa.open_item_id = i.id and fa.tenant_id = v_tenant
      join public.fin_settlements s
        on s.id = fa.settlement_id and s.tenant_id = v_tenant and s.direction = 'in'
       and s.settlement_date <= p_to
       and (s.status = 'posted' or (s.status = 'void' and public.ins_local_date(s.voided_at) > p_to))
  ),
  coll_r as (
    select c.*, trunc(c.exact, 2) as base,
           row_number() over (partition by c.fa_id order by c.exact - trunc(c.exact, 2) desc, c.aid) as rk,
           round((round(sum(c.exact) over (partition by c.fa_id), 2)
                  - sum(trunc(c.exact, 2)) over (partition by c.fa_id)) * 100)::integer as cents
      from coll c
  ),
  -- Remittances: an insurer remittance settles the share's payable open item;
  -- the charge share is the remittance times the allocation over the payable.
  rem as (
    select fa.id as fa_id, s.id as settlement_id, s.settlement_no, s.settlement_date,
           fa.amount as fa_amount, i.amount as base_amount, a.aid, a.amount as a_amount,
           fa.amount * a.amount / i.amount as exact
      from a
      join public.fin_open_items i
        on i.tenant_id = v_tenant and i.control_role = 'insurer_payable' and i.amount > 0
       and ((i.source_type = 'ins_policy_share_insurer' and i.source_id = a.insurer_share_id)
            -- a single-insurer policy bound without a share configuration carries its payable
            -- against the policy itself
            or (i.source_type = 'ins_policy_insurer' and i.source_id = a.policy_id))
      join public.fin_allocations fa on fa.open_item_id = i.id and fa.tenant_id = v_tenant
      join public.fin_settlements s
        on s.id = fa.settlement_id and s.tenant_id = v_tenant and s.direction = 'out'
       and s.settlement_date <= p_to
       and (s.status = 'posted' or (s.status = 'void' and public.ins_local_date(s.voided_at) > p_to))
  ),
  rem_r as (
    select c.*, trunc(c.exact, 2) as base,
           row_number() over (partition by c.fa_id order by c.exact - trunc(c.exact, 2) desc, c.aid) as rk,
           round((round(sum(c.exact) over (partition by c.fa_id), 2)
                  - sum(trunc(c.exact, 2)) over (partition by c.fa_id)) * 100)::integer as cents
      from rem c
  ),
  rows_all as (
    select 'assessed'::text as stg, a.aid, a.bound_date as ev_date, null::uuid as set_id, null::text as set_no,
           a.amount as amt,
           'charge line allocated to the insurer share'::text as bas
      from a
    union all
    select 'collected', r.aid, r.settlement_date, r.settlement_id, r.settlement_no,
           r.base + case when r.rk <= r.cents then 0.01 else 0 end,
           format('pro rata: receipt %s x allocation %s / invoice %s', r.fa_amount, r.a_amount, r.base_amount)
      from coll_r r
    union all
    select 'remitted', r.aid, r.settlement_date, r.settlement_id, r.settlement_no,
           r.base + case when r.rk <= r.cents then 0.01 else 0 end,
           format('pro rata: remittance %s x allocation %s / payable %s', r.fa_amount, r.a_amount, r.base_amount)
      from rem_r r
  )
  select ra.stg, to_char(a.bound_date, 'YYYY-MM'), a.policy_id, a.policy_no, bd.name, a.policy_status,
         a.insurer_id, ins.name, a.charge_id, a.charge_code, a.charge_name, a.charge_class,
         a.collector, a.recipient_name, a.payable_role, a.currency,
         ra.ev_date, ra.set_id, ra.set_no, ra.amt, ra.bas
    from rows_all ra
    join a on a.aid = ra.aid
    left join public.ins_clients cl on cl.id = a.client_id
    left join public.bd_clients bd on bd.id = cl.client_id
    left join public.ins_insurers ins on ins.id = a.insurer_id
   order by a.currency, a.charge_code, a.policy_no, ra.stg, ra.ev_date, ra.set_no;
end;
$$;
revoke all on function public.ins_report_statutory_charge_trace(date, date, boolean, boolean) from public, anon;
grant execute on function public.ins_report_statutory_charge_trace(date, date, boolean, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 4. The summary, aggregated from the trace
-- ---------------------------------------------------------------------
create or replace function public.ins_report_statutory_charges(
  p_from             date,
  p_to               date,
  p_group_by         text default 'charge',
  p_include_imported boolean default false,
  p_include_manual   boolean default false
)
returns table (
  group_key        text,
  group_label      text,
  currency         text,
  policy_count     integer,
  assessed         numeric,
  collected        numeric,
  uncollected      numeric,
  remitted         numeric,
  held_unremitted  numeric,
  remitter         text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if auth.uid() is null or not (public.can_access_insurance() or public.is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN: insurance or finance access is required' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'INS_REPORT_INPUT: a valid period is required';
  end if;
  if p_group_by is null or p_group_by not in ('charge', 'insurer', 'month', 'client') then
    raise exception 'INS_REPORT_INPUT: group by must be charge, insurer, month or client';
  end if;

  return query
  with t as (
    select * from public.ins_report_statutory_charge_trace(p_from, p_to, p_include_imported, p_include_manual)
  ),
  keyed as (
    select t.*,
           case p_group_by
             when 'charge'  then t.charge_code
             when 'insurer' then coalesce(t.insurer_id::text, 'none')
             when 'month'   then t.cohort_month
             when 'client'  then coalesce(t.client_name, '(none)')
           end as k,
           case p_group_by
             when 'charge'  then coalesce(t.charge_name, t.charge_code)
             when 'insurer' then coalesce(t.insurer_name, '(none)')
             when 'month'   then t.cohort_month
             when 'client'  then coalesce(t.client_name, '(none)')
           end as lbl
      from t
  )
  select k.k, min(k.lbl), k.currency,
         count(distinct k.policy_id) filter (where k.stage = 'assessed')::integer,
         coalesce(sum(k.amount) filter (where k.stage = 'assessed'), 0),
         coalesce(sum(k.amount) filter (where k.stage = 'collected'), 0),
         coalesce(sum(k.amount) filter (where k.stage = 'assessed'), 0)
           - coalesce(sum(k.amount) filter (where k.stage = 'collected'), 0),
         coalesce(sum(k.amount) filter (where k.stage = 'remitted'), 0),
         coalesce(sum(k.amount) filter (where k.stage = 'collected'), 0)
           - coalesce(sum(k.amount) filter (where k.stage = 'remitted'), 0),
         case when count(distinct k.collector) = 1
              then case min(k.collector) when 'insurer' then 'insurer' else 'brokerage' end
              else 'mixed' end
    from keyed k
   group by k.k, k.currency
   order by k.currency, k.k;
end;
$$;
revoke all on function public.ins_report_statutory_charges(date, date, text, boolean, boolean) from public, anon;
grant execute on function public.ins_report_statutory_charges(date, date, text, boolean, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Reconciliation exceptions
-- ---------------------------------------------------------------------
-- A policy is listed when something does not tie:
--   allocation   the allocation rows differ from the booked pass_through_amount
--                on the insurer shares (a share is listed with its difference)
--   ledger       the bind journal's credit to the insurer payable account
--                differs from the shares' payable amounts
-- An empty result is the reconciliation passing.
create or replace function public.ins_report_statutory_charge_exceptions(
  p_from             date,
  p_to               date,
  p_include_imported boolean default false
)
returns table (
  check_name        text,
  policy_id         uuid,
  policy_no         text,
  insurer_name      text,
  recorded_amount   numeric,
  booked_amount     numeric,
  difference        numeric
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_payable_gl uuid;
begin
  if auth.uid() is null or not (public.can_access_insurance() or public.is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN: insurance or finance access is required' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'INS_REPORT_INPUT: a valid period is required';
  end if;

  select r.gl_account_id into v_payable_gl
    from public.gl_posting_rules r
   where r.tenant_id = v_tenant and r.account_role = 'insurer_payable';

  return query
  with pols as (
    select p.id, p.policy_no, p.journal_entry_id
      from public.ins_policies p
     where p.tenant_id = v_tenant
       and p.bound_at is not null
       and public.ins_local_date(p.bound_at) between p_from and p_to
       and (p_include_imported or p.import_batch_id is null)
       and exists (select 1 from public.ins_policy_insurer_shares s
                    where s.policy_id = p.id and s.pass_through_amount > 0)
  ),
  alloc as (
    select s.policy_id, s.id as share_id, i.name as insurer_name, s.pass_through_amount as booked,
           coalesce((select sum(al.amount) from public.ins_policy_charge_allocations al
                      where al.insurer_share_id = s.id), 0) as recorded
      from public.ins_policy_insurer_shares s
      join pols on pols.id = s.policy_id
      left join public.ins_insurers i on i.id = s.insurer_id
  ),
  ledger as (
    select pols.id as policy_id, pols.policy_no,
           coalesce((select sum(l.credit - l.debit) from public.journal_entry_lines l
                      where l.journal_entry_id = pols.journal_entry_id and l.gl_account_id = v_payable_gl), 0) as journal_credit,
           (select coalesce(sum(s.payable_amount), 0) from public.ins_policy_insurer_shares s
             where s.policy_id = pols.id) as shares_payable
      from pols
  )
  select 'allocation'::text, pols.id, pols.policy_no, a.insurer_name, a.recorded, a.booked, a.recorded - a.booked
    from alloc a join pols on pols.id = a.policy_id
   where a.recorded <> a.booked
  union all
  select 'ledger'::text, l.policy_id, l.policy_no, null::text, l.journal_credit, l.shares_payable, l.journal_credit - l.shares_payable
    from ledger l
   where v_payable_gl is not null and l.journal_credit <> l.shares_payable
  order by 1, 3, 4;
end;
$$;
revoke all on function public.ins_report_statutory_charge_exceptions(date, date, boolean) from public, anon;
grant execute on function public.ins_report_statutory_charge_exceptions(date, date, boolean) to authenticated;

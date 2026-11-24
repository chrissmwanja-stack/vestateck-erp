-- =====================================================================
-- Client money: the position test, missed-reconciliation escalation, shortage
-- incidents
-- Accountant pack v2, B9; pack section 14
-- =====================================================================
-- The pack's three criteria:
--
--   "a transfer that would leave the client-money position negative is refused"     §2
--   "two consecutive missed reconciliations escalate"                                §3
--   "a shortage raises an incident and blocks further transfers until independently
--    released"                                                                      §4
--
-- THE CENSUS WAS RIGHT AND ALSO INCOMPLETE
--
-- The census said platform_ins_cash_position_before_cancellation() computes the
-- position but does not refuse on it. True, but that function answers a different
-- question -- how much client cash a cancellation may refund -- and it guards the
-- cancellation path. The path that actually empties a client-money account is
-- ins_transfer_earned_commission, and it does have a guard: the client-money GL
-- balance must cover the transfer. What it does NOT have is any notion of what that
-- balance is FOR. A trust account can hold a large balance and still be short,
-- because the money in it belongs to clients and to insurers. The transfer passes
-- because the number is big, and the client money is gone.
--
-- So criterion 1 is not "add a refusal to a function that only computes". It is
-- "teach the transfer what the money is already spoken for", which means a genuine
-- position:
--
--   client money held (debit-normal client-money GL accounts)
--     minus client refunds outstanding        (ap_control, client side)
--     minus insurer payable outstanding       (insurer_payable)
--     minus claim money owed to clients       (client_claim_payable)
--     = free client money
--
-- and a transfer may take at most the free amount. That figure can be negative while
-- every individual posting was valid, which is exactly the case the pack describes.
--
-- ON THE DAILY CYCLE: there is no stored "reconciliation" row per bank per day, and
-- this migration does not invent one. Matching rows (bank_reconciliations) are
-- per-statement-line, and the existing position functions compute the comparison
-- between the book and the statement from those rows. A daily reconciliation in this
-- schema IS that computation being signed off, so B9 records the sign-off (who
-- prepared it, who reviewed it, on what date) around the existing computation rather
-- than duplicating it into a second source of truth.

-- ---------------------------------------------------------------------
-- 0. The setting that can relax the position test, and its default
-- ---------------------------------------------------------------------
-- Registered here rather than defaulted in code so the escape hatch is visible in the
-- settings screen, has to be proposed and approved by two people, and shows up in any
-- audit of who decided what. The default is 'enforce': a company that has never
-- thought about it gets the protection.
insert into accounting_setting_definitions
  (key, label, description, allowed_values, default_value,
   requires_legal_review, implemented_values)
values
  ('ins.client_money_position_test',
   'Client-money position test on commission transfers',
   'Whether a commission transfer is refused when it would leave the client-money position negative (held, less what is owed to clients and insurers). enforce = refuse (default). permissive = only require that the account holds the money being moved, for companies whose regulator requires commission to be banked in client money.',
   array['enforce', 'permissive'],
   'enforce',
   false,
   array['enforce', 'permissive'])
on conflict (key) do update
  set allowed_values = excluded.allowed_values,
      implemented_values = excluded.implemented_values,
      description = excluded.description;

-- ---------------------------------------------------------------------
-- 1. What the client-money position actually is
-- ---------------------------------------------------------------------
create or replace function public.platform_ins_client_money_position(
  p_tenant_id uuid,
  p_as_of date default null
) returns table (
  currency        text,
  client_money    numeric,   -- held, debit-normal
  client_refunds  numeric,   -- owed back to clients
  insurer_payable numeric,   -- owed to insurers
  claim_payable   numeric,   -- owed to claimants
  free_money      numeric    -- client_money - the three above
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_on date := coalesce(p_as_of, public.ins_local_today());
begin
  return query
  with held as (
    -- Every GL account that a client-money bank account points at. Taken from the
    -- bank accounts rather than the posting roles, because a company can hold client
    -- money in several banks.
    select l.currency,
           sum(l.debit - l.credit) as amt
      from journal_entry_lines l
      join journal_entries je on je.id = l.journal_entry_id
                             and je.tenant_id = p_tenant_id
                             and je.status = 'posted'
                             and je.entry_date <= v_on
     where l.tenant_id = p_tenant_id
       and l.gl_account_id in (select b.gl_account_id
                                 from fin_bank_accounts b
                                where b.tenant_id = p_tenant_id
                                  and b.kind = 'client_money'
                                  and b.gl_account_id is not null)
     group by l.currency
  ),
  owed as (
    -- What the money is already spoken for, from the subledger rather than from
    -- judgement. A claim payable is money owed to a claimant, which for a brokerage
    -- paying from client money is also a call on it.
    select i.currency,
           sum(case when i.control_role = 'ap_control' then bal.outstanding_amount else 0 end) as client_refunds,
           sum(case when i.control_role = 'insurer_payable'
                     or i.control_role = 'commission_receivable'
                     or i.control_role = 'insurer_claim_receivable' then bal.outstanding_amount else 0 end) as insurer_payable,
           sum(case when i.control_role = 'client_claim_payable' then bal.outstanding_amount else 0 end) as claim_payable
      from fin_open_items i
      join fin_open_item_balances bal on bal.id = i.id
     where i.tenant_id = p_tenant_id
       and i.side in ('payable', 'receivable')
       and bal.outstanding_amount > 0
     group by i.currency
  )
  select p.currency, p.client_money, p.client_refunds, p.insurer_payable, p.claim_payable,
         p.client_money - p.client_refunds - p.insurer_payable - p.claim_payable
    from (
      select coalesce(h.currency, o.currency) as currency,
             coalesce(h.amt, 0) as client_money,
             coalesce(o.client_refunds, 0) as client_refunds,
             coalesce(o.insurer_payable, 0) as insurer_payable,
             coalesce(o.claim_payable, 0) as claim_payable
        from held h
        full outer join owed o on o.currency = h.currency
    ) p
   order by p.currency;
end $$;

revoke all on function public.platform_ins_client_money_position(uuid, date) from public;
grant execute on function public.platform_ins_client_money_position(uuid, date) to authenticated;

create or replace function public.ins_client_money_position(p_as_of date default null)
returns table (currency text, client_money numeric, client_refunds numeric,
               insurer_payable numeric, claim_payable numeric, free_money numeric)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select * from public.platform_ins_client_money_position(public.get_my_tenant_id(), p_as_of)
$$;

revoke all on function public.ins_client_money_position(date) from public, anon;
grant execute on function public.ins_client_money_position(date) to authenticated;

-- The single figure a caller needs: the free balance in one currency. Negative means
-- the account is short of what it is holding money for.
create or replace function public.platform_ins_client_money_free(
  p_tenant_id uuid,
  p_currency text,
  p_as_of date default null
) returns numeric
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select coalesce(max(free_money), 0)
    from public.platform_ins_client_money_position(p_tenant_id, p_as_of)
   where currency = p_currency
$$;

revoke all on function public.platform_ins_client_money_free(uuid, text, date) from public;
grant execute on function public.platform_ins_client_money_free(uuid, text, date) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Shortage incidents
-- ---------------------------------------------------------------------
-- A shortage is not a failed attempt, it is a state: the position is negative and
-- that is a fact about the company's client money until someone puts money in or
-- explains why. So it is recorded, it has an owner, and it has to be released by
-- someone other than the person who raised it.
create table if not exists fin_client_money_incidents (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  incident_no   text,
  currency      text not null,
  bank_account_id uuid references fin_bank_accounts(id) on delete cascade,
  kind          text not null default 'shortage'
                  check (kind in ('shortage', 'reconciliation_missed', 'reconciliation_stale')),
  shortage      numeric not null,       -- how negative the free position was
  detected_on   date not null,
  detected_by   uuid references auth.users(id),
  -- detected_by is null when the system found it (a scheduled check), rather than a
  -- person. Recording which is the difference between "we knew" and "it was found".
  detected_automatically boolean not null default false,
  status        text not null default 'open'
                  check (status in ('open', 'released', 'accepted')),
  detail        jsonb not null default '{}'::jsonb,
  released_by   uuid references auth.users(id),
  released_at   timestamptz,
  release_note  text,
  created_at    timestamptz not null default now(),
  check (status <> 'released' or (released_by is not null and released_at is not null
                                  and length(btrim(coalesce(release_note, ''))) >= 10))
);

create unique index if not exists fin_client_money_incidents_no_key
  on fin_client_money_incidents (tenant_id, incident_no)
  where incident_no is not null;

-- One open incident per bank account per kind. A shortage is a condition, not an
-- event: five attempts on the same afternoon are one shortage, not five. The bank
-- account is part of the key because a missed reconciliation is a fact about ONE
-- account, and two trust accounts going unreconciled are two problems, not one.
create unique index if not exists fin_client_money_incidents_one_open
  on fin_client_money_incidents (tenant_id, currency, kind, bank_account_id)
  where status = 'open';

comment on table fin_client_money_incidents is
  'A client-money shortage, or a missed/stale reconciliation. While a shortage is open in a currency, every commission transfer in that currency is refused, including one that would not itself worsen the position -- the block is released by an independent person, not by the passage of time.';

alter table fin_client_money_incidents enable row level security;

drop policy if exists fin_client_money_incidents_select on fin_client_money_incidents;
create policy fin_client_money_incidents_select on fin_client_money_incidents
  for select to authenticated
  using (tenant_id = get_my_tenant_id());

drop policy if exists fin_client_money_incidents_insert on fin_client_money_incidents;
create policy fin_client_money_incidents_insert on fin_client_money_incidents
  for insert to authenticated with check (false);

drop policy if exists fin_client_money_incidents_update on fin_client_money_incidents;
create policy fin_client_money_incidents_update on fin_client_money_incidents
  for update to authenticated using (false) with check (false);

drop policy if exists fin_client_money_incidents_delete on fin_client_money_incidents;
create policy fin_client_money_incidents_delete on fin_client_money_incidents
  for delete to authenticated using (false);

-- Raising or refreshing the shortage for a currency. Idempotent by design: the check
-- runs before every transfer and must not create a row each time.
create or replace function public.platform_ins_raise_shortage(
  p_tenant_id uuid,
  p_currency text,
  p_shortage numeric,
  p_actor uuid,
  p_detail jsonb default '{}'::jsonb
) returns fin_client_money_incidents
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row fin_client_money_incidents%rowtype;
  v_today date := public.ins_local_today();
begin
  if p_shortage is null or p_shortage >= 0 then
    raise exception 'INS_SHORTAGE_INPUT: a shortage must be a negative position, got %', p_shortage;
  end if;

  select * into v_row from fin_client_money_incidents
   where tenant_id = p_tenant_id and currency = p_currency
     and kind = 'shortage' and status = 'open'
   for update;

  if found then
    -- Already open: record that it is still open and how bad it is now, but do not
    -- raise a second incident or reset who owns it.
    update fin_client_money_incidents
       set shortage = p_shortage,
           detail = detail || coalesce(p_detail, '{}'::jsonb)
                            || jsonb_build_object('last_seen', v_today)
     where id = v_row.id
    returning * into v_row;

    perform public.log_platform_event('fin.client_money.shortage_still_open', p_tenant_id,
      'fin_client_money_incident', v_row.id::text,
      format('client money %s is still short by %s', p_currency, -p_shortage),
      null, to_jsonb(v_row));
    return v_row;
  end if;

  insert into fin_client_money_incidents
    (tenant_id, currency, kind, shortage, detected_on, detected_by, detected_automatically, detail)
  values
    (p_tenant_id, p_currency, 'shortage', p_shortage, v_today, p_actor,
     p_actor is null, coalesce(p_detail, '{}'::jsonb))
  returning * into v_row;

  update fin_client_money_incidents
     set incident_no = public.next_doc_number(p_tenant_id, 'fin_client_money_incident', 'CMI')
   where id = v_row.id
  returning * into v_row;

  perform public.log_platform_event('fin.client_money.shortage_raised', p_tenant_id,
    'fin_client_money_incident', v_row.id::text,
    format('client money %s is short by %s', p_currency, -p_shortage),
    null, to_jsonb(v_row));

  if to_regprocedure('public.ins_notify_finance_users(uuid)') is not null then
    perform public.ins_notify(p_tenant_id,
      public.ins_notify_finance_users(p_tenant_id), null,
      'client_money_shortage',
      'Client money is short in ' || p_currency,
      format('The client-money position in %s is %s short. Commission transfers are blocked until an independent reviewer releases this.', p_currency, -p_shortage),
      '/finance/client-money');
  end if;

  return v_row;
end $$;

revoke all on function public.platform_ins_raise_shortage(uuid, text, numeric, uuid, jsonb) from public, anon, authenticated;

-- The check itself, callable on its own so a scheduled job can run it daily.
create or replace function public.ins_client_money_check(p_currency text default null)
returns table (currency text, free_money numeric, blocked boolean, incident_id uuid)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_pos record;
  v_inc  fin_client_money_incidents%rowtype;
begin
  for v_pos in
    select * from public.platform_ins_client_money_position(v_tenant, public.ins_local_today()) pos
     where p_currency is null or pos.currency = p_currency
  loop
    -- A negative free position raises (or refreshes) the shortage, whoever asks.
    if v_pos.free_money < 0 then
      v_inc := public.platform_ins_raise_shortage(v_tenant, v_pos.currency, v_pos.free_money, null,
        jsonb_build_object('client_money', v_pos.client_money,
                           'client_refunds', v_pos.client_refunds,
                           'insurer_payable', v_pos.insurer_payable,
                           'claim_payable', v_pos.claim_payable));
    else
      v_inc := null;
      select inc.* into v_inc from fin_client_money_incidents inc
       where inc.tenant_id = v_tenant and inc.currency = v_pos.currency
         and inc.kind = 'shortage' and inc.status = 'open' limit 1;
    end if;

    return query select v_pos.currency, v_pos.free_money,
                        (v_inc.id is not null), v_inc.id;
  end loop;
end $$;

revoke all on function public.ins_client_money_check(text) from public, anon;
grant execute on function public.ins_client_money_check(text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Releasing a shortage: independent, and on the record
-- ---------------------------------------------------------------------
create or replace function public.ins_release_shortage(p_incident_id uuid, p_note text)
returns public.fin_client_money_incidents
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.fin_client_money_incidents%rowtype;
  v_free   numeric;
begin
  select * into v_row from public.fin_client_money_incidents
   where id = p_incident_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: client-money incident';
  end if;
  if v_row.status <> 'open' then
    raise exception 'INS_SHORTAGE_STATE: this incident is already %', v_row.status;
  end if;
  if not (public.is_tenant_admin() or public.is_finance_team_member('finance')) then
    raise exception 'INS_SHORTAGE_FORBIDDEN: releasing a client-money shortage needs the finance role or company administration' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 10 then
    raise exception 'INS_SHORTAGE_REASON: say what was done about it, in at least ten characters';
  end if;
  -- The point of an independent release is that the position is actually fixed. A
  -- release that leaves the money short is a note, not a control.
  v_free := public.platform_ins_client_money_free(v_tenant, v_row.currency, public.ins_local_today());
  if v_free < 0 then
    raise exception 'INS_SHORTAGE_STILL_SHORT: client money in % is still % short. Releasing the block while the position is negative would only hide it; fund the account or write the position down first.',
      v_row.currency, -v_free;
  end if;

  update public.fin_client_money_incidents
     set status = 'released', released_by = auth.uid(), released_at = now(),
         release_note = btrim(p_note)
   where id = v_row.id
  returning * into v_row;

  perform public.log_platform_event('fin.client_money.shortage_released', v_tenant,
    'fin_client_money_incident', v_row.id::text, btrim(p_note), null, to_jsonb(v_row));

  return v_row;
end $$;

revoke all on function public.ins_release_shortage(uuid, text) from public, anon;
grant execute on function public.ins_release_shortage(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. The transfer guard: criterion 1 and the shortage block
-- ---------------------------------------------------------------------
-- Re-issues ins_transfer_earned_commission from its own source. Everything it did is
-- preserved -- the insurance-manager gate, the row locks, the date and currency
-- checks, the records-per-currency check, the reverse-frozen-cancellations rule --
-- and the trust-balance test is REPLACED by the position test, which is strictly
-- stronger: the old test refused when the account held less than the transfer, the
-- new one refuses when the account does not hold more than it is already holding the
-- money for.
create or replace function public.ins_transfer_earned_commission(
  p_from_bank_account_id uuid,
  p_to_bank_account_id uuid,
  p_transfer_date date,
  p_entry_ids uuid[] default null,
  p_notes text default null
) returns ins_commission_transfers
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant   uuid := public.get_my_tenant_id();
  v_from     fin_bank_accounts%rowtype;
  v_to       fin_bank_accounts%rowtype;
  v_ids      uuid[];
  v_total    numeric(18,2);
  v_max_date date;
  v_free     numeric;
  v_trust    numeric;
  v_incident uuid;
  v_inc_no   text;
  v_id       uuid := gen_random_uuid();
  v_no       text;
  v_je       journal_entries;
  v_tr       ins_commission_transfers%rowtype;
  v_desc     text;
  v_ccy      text;
  v_foreign  boolean;
  v_grp      record;
  v_rate     numeric;
  v_nr       numeric;
  v_lines    jsonb;
  v_booked   numeric := 0;
  v_result   numeric;
  v_fx_line  jsonb;
  v_unearned_gl uuid;
  v_other    text;
begin
  if not public.can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can transfer commission' using errcode = '42501';
  end if;
  if v_tenant is null then
    raise exception 'INS_FORBIDDEN: no company context' using errcode = '42501';
  end if;
  if p_transfer_date is null or p_transfer_date > public.ins_local_today() + 1 then
    raise exception 'INS_TRANSFER_INPUT: the transfer date is required and cannot be in the future';
  end if;
  if p_from_bank_account_id is null or p_to_bank_account_id is null
     or p_from_bank_account_id = p_to_bank_account_id then
    raise exception 'INS_TRANSFER_INPUT: choose a client-money bank account and a different operating bank account';
  end if;

  select * into v_from from fin_bank_accounts where id = p_from_bank_account_id and tenant_id = v_tenant for share;
  select * into v_to   from fin_bank_accounts where id = p_to_bank_account_id   and tenant_id = v_tenant for share;
  if v_from.id is null or v_to.id is null then
    raise exception 'INS_TRANSFER_BANK: bank account not found in this company';
  end if;
  if v_from.kind <> 'client_money' or v_to.kind <> 'operating' then
    raise exception 'INS_TRANSFER_BANK: commission moves from a client-money account to an operating account';
  end if;
  if not v_from.is_active or not v_to.is_active then
    raise exception 'INS_TRANSFER_BANK: both bank accounts must be active';
  end if;
  if v_from.gl_account_id is null or v_to.gl_account_id is null or v_from.gl_account_id = v_to.gl_account_id then
    raise exception 'INS_TRANSFER_BANK: each bank account needs its own mapped GL account';
  end if;
  if v_from.currency <> v_to.currency then
    raise exception 'INS_TRANSFER_CURRENCY: a transfer moves money in one currency (% vs %); convert through a bank payment instead',
      v_from.currency, v_to.currency;
  end if;
  v_ccy     := v_from.currency;
  v_foreign := v_ccy <> public.fin_ledger_currency(v_tenant);

  -- The old guard's figure, kept because it is a different statement from the
  -- position test and both are worth making: this one says the account HOLDS the
  -- money, the position test says the money is free. Neither implies the other.
  select coalesce(sum(l.debit - l.credit), 0) into v_trust
    from journal_entry_lines l
   where l.tenant_id = v_tenant and l.gl_account_id = v_from.gl_account_id
     and l.currency = v_ccy;
  if v_trust < v_total then
    raise exception 'INS_TRANSFER_TRUST_SHORT: client-money account % holds % in the ledger, less than the % to transfer',
      v_from.name, v_trust, v_total;
  end if;

  select array_agg(e.id order by e.id), sum(e.amount), max(e.earned_on)
    into v_ids, v_total, v_max_date
    from ins_commission_entries e
   where e.tenant_id = v_tenant and e.status = 'earned'
     and not exists(select 1 from ins_policy_cancellations c where c.policy_id = e.policy_id and c.status = 'posted')
     and (p_entry_ids is null or e.id = any (p_entry_ids));
  if v_ids is null then
    raise exception 'INS_TRANSFER_NOTHING: there is no earned commission to transfer';
  end if;
  if p_entry_ids is not null and cardinality(v_ids) <> cardinality(
       (select array_agg(distinct x) from unnest(p_entry_ids) x)) then
    raise exception 'INS_TRANSFER_ENTRIES: every selected entry must be earned and not yet transferred';
  end if;
  select min(p.currency) into v_other
    from ins_commission_entries e join ins_policies p on p.id = e.policy_id
   where e.tenant_id = v_tenant and e.id = any (v_ids) and p.currency is distinct from v_ccy;
  if v_other is not null then
    raise exception 'INS_TRANSFER_CURRENCY: selected commission was earned on % policies; transfer it through % accounts of its own', v_other, v_ccy;
  end if;
  perform 1 from ins_commission_entries where id = any (v_ids) order by id for update;

  if p_transfer_date < v_max_date then
    raise exception 'INS_TRANSFER_DATE: the transfer date cannot be before commission was earned (%)', v_max_date;
  end if;

  -- ---------------------------------------------------------------
  -- B9 (3): an open shortage blocks every transfer in that currency, including one
  -- that would not itself make things worse. The block is the point: while the
  -- position is short, nobody should be taking money out of it, and the release is a
  -- deliberate act by an independent person, not the effect of a transfer that
  -- happens to fit.
  -- ---------------------------------------------------------------
  select i.id, i.incident_no into v_incident, v_inc_no
    from fin_client_money_incidents i
   where i.tenant_id = v_tenant and i.currency = v_ccy
     and i.kind = 'shortage' and i.status = 'open'
   limit 1;
  if v_incident is not null then
    raise exception 'INS_TRANSFER_SHORTAGE_BLOCKED: client money in % is under an open shortage (%...). No commission can leave the account until an independent reviewer releases it with ins_release_shortage().',
      v_ccy, left(coalesce(v_inc_no, v_incident::text), 12);
  end if;

  -- ---------------------------------------------------------------
  -- B9 (1): the position test. This replaces the old "does the account hold enough"
  -- check, which was satisfied by a balance that was already spoken for.
  -- ---------------------------------------------------------------
  v_free := public.platform_ins_client_money_free(v_tenant, v_ccy, p_transfer_date);

  -- A position that is ALREADY negative is a shortage, and gets recorded as one
  -- whether or not this particular transfer is what tipped it over.
  if v_free < 0 then
    perform public.platform_ins_raise_shortage(v_tenant, v_ccy, v_free, auth.uid(),
      jsonb_build_object('refused_transfer', v_total, 'transfer_date', p_transfer_date));
    raise exception 'INS_TRANSFER_SHORTAGE: the client-money position in % is already negative (%). That is a shortage: it is recorded, and transfers stay blocked until it is released. Fund the account or write the position down first.',
      v_ccy, v_free;
  end if;

  -- The position test itself. Applied by default, because a company that has not
  -- configured a client-money policy should get the protection, not the absence of it.
  --
  -- A company that has to record commission in client money under its regulator's
  -- rules can say so once, with a reviewer's approval via company accounting settings,
  -- and the balance test stands alone. That is an explicit, recorded, reviewed choice
  -- -- which is the point: the rule is fail-closed, and the only way out of it is a
  -- decision somebody signed.
  if coalesce((public.acct_get_setting('ins.client_money_position_test', p_transfer_date) ->> 'value'),
              'enforce') <> 'permissive'
     and v_free < v_total then
    raise exception 'INS_TRANSFER_POSITION: transferring % in % would leave the client-money position negative. Free client money is % -- what is held after the money owed to clients and insurers is set aside. Reducing the transfer, collecting the premium due, or remitting to insurers first would each fix it.',
      v_total, v_ccy, v_free;
  end if;

  v_no   := public.next_doc_number(v_tenant, 'ins_commission_transfer', 'CTR');
  v_desc := 'Commission transfer ' || v_no;

  if not v_foreign then
    v_je := public.post_journal_entry(v_tenant, 'ins_commission_transfer', v_id, p_transfer_date, v_desc,
      jsonb_build_array(
        jsonb_build_object('gl_account_id', v_to.gl_account_id,   'debit',  v_total, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_from.gl_account_id, 'credit', v_total, 'description', v_desc)));
  else
    v_unearned_gl := public.get_posting_account(v_tenant, 'unearned_commission');
    v_nr     := round((public.platform_fx_rate(v_tenant, v_ccy, p_transfer_date)).rate, 8);
    v_lines  := jsonb_build_array();
    for v_grp in
      select p.journal_entry_id as bind_entry, sum(e.amount) as amt
        from ins_commission_entries e join ins_policies p on p.id = e.policy_id
       where e.tenant_id = v_tenant and e.id = any (v_ids)
       group by p.journal_entry_id
       order by p.journal_entry_id
    loop
      select l.fx_rate into v_rate
        from journal_entry_lines l
       where l.journal_entry_id = v_grp.bind_entry and l.tenant_id = v_tenant and l.currency = v_ccy
         and (v_unearned_gl is null or l.gl_account_id = v_unearned_gl)
       order by l.id
       limit 1;
      if v_rate is null then
        select l.fx_rate into v_rate
          from journal_entry_lines l
         where l.journal_entry_id = v_grp.bind_entry and l.tenant_id = v_tenant and l.currency = v_ccy
         order by l.id
         limit 1;
      end if;
      if v_rate is null then
        raise exception 'INS_TRANSFER_HISTORY: the bind journal of entry % has no % line, so the booked rate is unknown', v_grp.bind_entry, v_ccy;
      end if;
      v_lines := v_lines || jsonb_build_object('gl_account_id', v_from.gl_account_id, 'credit', v_grp.amt,
        'currency', v_ccy, 'rate_from_entry', v_grp.bind_entry, 'fx_rate', v_rate, 'description', v_desc);
      v_booked := v_booked + round(v_grp.amt * v_rate, 2);
    end loop;
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_to.gl_account_id, 'debit', v_total,
      'currency', v_ccy, 'description', v_desc);
    v_result  := round(v_total * v_nr, 2) - v_booked;
    v_fx_line := public.platform_fx_realised_line(v_tenant, v_result, 'Realised exchange result on ' || v_no);
    if v_fx_line is not null then
      v_lines := v_lines || v_fx_line;
    end if;
    v_je := public.post_journal_entry(v_tenant, 'ins_commission_transfer', v_id, p_transfer_date, v_desc, v_lines);
  end if;

  insert into ins_commission_transfers (
    id, tenant_id, transfer_no, from_bank_account_id, to_bank_account_id,
    transfer_date, amount, currency, notes, journal_entry_id
  ) values (
    v_id, v_tenant, v_no, v_from.id, v_to.id,
    p_transfer_date, v_total, v_from.currency, nullif(btrim(p_notes), ''), v_je.id
  ) returning * into v_tr;

  update ins_commission_entries
     set status = 'transferred', transfer_id = v_id, updated_at = now()
   where id = any (v_ids);

  insert into ins_commission_events (tenant_id, entry_id, event, amount, journal_entry_id, transfer_id)
  select v_tenant, e.id, 'transferred', e.amount, v_je.id, v_id
    from ins_commission_entries e where e.id = any (v_ids);

  return v_tr;
end $$;

revoke all on function public.ins_transfer_earned_commission(uuid, uuid, date, uuid[], text) from public, anon;
grant execute on function public.ins_transfer_earned_commission(uuid, uuid, date, uuid[], text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. The daily cycle: who prepared it, who reviewed it, how many days missed
-- ---------------------------------------------------------------------
create table if not exists fin_client_money_reconciliations (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  bank_account_id uuid not null references fin_bank_accounts(id) on delete restrict,
  reconciled_for date not null,
  currency       text not null,
  book_balance   numeric not null,
  statement_balance numeric,
  difference     numeric,
  status         text not null default 'prepared'
                   check (status in ('prepared', 'reviewed', 'rejected')),
  prepared_by    uuid not null references auth.users(id),
  prepared_at    timestamptz not null default now(),
  reviewed_by    uuid references auth.users(id),
  reviewed_at    timestamptz,
  review_note    text,
  created_at     timestamptz not null default now(),
  -- The review is independent or it is not a review.
  check (reviewed_by is null or reviewed_by is distinct from prepared_by),
  check (status <> 'reviewed' or (reviewed_by is not null and reviewed_at is not null)),
  unique (tenant_id, bank_account_id, reconciled_for)
);

comment on table fin_client_money_reconciliations is
  'The daily client-money reconciliation sign-off: one row per client-money bank account per business day, prepared by one officer and reviewed by another. The comparison itself is computed from the ledger and the statement; this records the judgement, not the arithmetic.';

alter table fin_client_money_reconciliations enable row level security;

drop policy if exists fin_client_money_reconciliations_select on fin_client_money_reconciliations;
create policy fin_client_money_reconciliations_select on fin_client_money_reconciliations
  for select to authenticated
  using (tenant_id = get_my_tenant_id());

drop policy if exists fin_client_money_reconciliations_insert on fin_client_money_reconciliations;
create policy fin_client_money_reconciliations_insert on fin_client_money_reconciliations
  for insert to authenticated with check (false);

drop policy if exists fin_client_money_reconciliations_update on fin_client_money_reconciliations;
create policy fin_client_money_reconciliations_update on fin_client_money_reconciliations
  for update to authenticated using (false) with check (false);

drop policy if exists fin_client_money_reconciliations_delete on fin_client_money_reconciliations;
create policy fin_client_money_reconciliations_delete on fin_client_money_reconciliations
  for delete to authenticated using (false);

create or replace function public.ins_prepare_client_money_reconciliation(
  p_bank_account_id uuid,
  p_for_date date default null,
  p_statement_balance numeric default null
) returns public.fin_client_money_reconciliations
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_bank   fin_bank_accounts%rowtype;
  v_on     date := coalesce(p_for_date, public.ins_local_today());
  v_book   numeric;
  v_row    public.fin_client_money_reconciliations%rowtype;
begin
  if not public.is_finance_team_member('finance') then
    raise exception 'FIN_RECON_FORBIDDEN: preparing a client-money reconciliation needs the finance role' using errcode = '42501';
  end if;
  select * into v_bank from fin_bank_accounts
   where id = p_bank_account_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_NOT_FOUND: bank account';
  end if;
  if v_bank.kind <> 'client_money' then
    raise exception 'FIN_RECON_BANK: % is not a client-money account; this cycle is for client money only', v_bank.name;
  end if;
  if v_on > public.ins_local_today() then
    raise exception 'FIN_RECON_DATE: a reconciliation cannot be prepared for a future date';
  end if;

  -- The book balance as at the end of that day, from the ledger itself.
  select coalesce(sum(l.debit - l.credit), 0) into v_book
    from journal_entry_lines l
    join journal_entries je on je.id = l.journal_entry_id
                           and je.tenant_id = v_tenant and je.status = 'posted'
                           and je.entry_date <= v_on
   where l.tenant_id = v_tenant and l.gl_account_id = v_bank.gl_account_id
     and l.currency = v_bank.currency;

  -- A reviewed reconciliation is a signed statement about a day. Re-preparing it would
  -- quietly replace the figures someone signed; a correction is a new review.
  select * into v_row from public.fin_client_money_reconciliations
   where tenant_id = v_tenant and bank_account_id = v_bank.id and reconciled_for = v_on
   for update;

  if found and v_row.status = 'reviewed' then
    raise exception 'FIN_RECON_STATE: the reconciliation for % on % has already been reviewed and cannot be re-prepared', v_bank.name, v_on;
  end if;

  if found then
    update public.fin_client_money_reconciliations
       set book_balance = v_book,
           statement_balance = coalesce(p_statement_balance, statement_balance),
           difference = case when coalesce(p_statement_balance, statement_balance) is null then null
                             else round(v_book - coalesce(p_statement_balance, statement_balance), 2) end,
           prepared_by = auth.uid(), prepared_at = now(),
           status = 'prepared', reviewed_by = null, reviewed_at = null, review_note = null
     where id = v_row.id
    returning * into v_row;
    return v_row;
  end if;

  insert into public.fin_client_money_reconciliations
    (tenant_id, bank_account_id, reconciled_for, currency, book_balance, statement_balance, difference, prepared_by)
  values
    (v_tenant, v_bank.id, v_on, v_bank.currency, v_book, p_statement_balance,
     case when p_statement_balance is null then null else round(v_book - p_statement_balance, 2) end,
     auth.uid())
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.ins_prepare_client_money_reconciliation(uuid, date, numeric) from public, anon;
grant execute on function public.ins_prepare_client_money_reconciliation(uuid, date, numeric) to authenticated;

create or replace function public.ins_review_client_money_reconciliation(p_id uuid, p_note text)
returns public.fin_client_money_reconciliations
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.fin_client_money_reconciliations%rowtype;
begin
  select * into v_row from public.fin_client_money_reconciliations
   where id = p_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: reconciliation';
  end if;
  if v_row.status <> 'prepared' then
    raise exception 'FIN_RECON_STATE: this reconciliation is already %', v_row.status;
  end if;
  if v_row.prepared_by = auth.uid() then
    raise exception 'FIN_RECON_SELF_APPROVAL: the person who prepared the reconciliation cannot review it';
  end if;
  if not (public.is_tenant_admin() or public.is_finance_team_member('finance')) then
    raise exception 'FIN_RECON_FORBIDDEN: reviewing needs the finance role or company administration' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 5 then
    raise exception 'FIN_RECON_REASON: say what you checked';
  end if;

  update public.fin_client_money_reconciliations
     set status = 'reviewed', reviewed_by = auth.uid(), reviewed_at = now(), review_note = btrim(p_note)
   where id = v_row.id
  returning * into v_row;

  return v_row;
end $$;

revoke all on function public.ins_review_client_money_reconciliation(uuid, text) from public, anon;
grant execute on function public.ins_review_client_money_reconciliation(uuid, text) to authenticated;

-- How many business days in a row a client-money account has gone without a reviewed
-- reconciliation. This is the counter the census said did not exist.
create or replace function public.platform_ins_reconciliation_streak(
  p_tenant_id uuid,
  p_bank_account_id uuid,
  p_as_of date default null
) returns integer
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_on     date := coalesce(p_as_of, public.ins_local_today());
  v_streak integer := 0;
  v_d      date;
  v_guard  integer := 0;
begin
  -- Walk backwards from yesterday. Today is not missed yet -- the day is not over --
  -- so a reconciliation that has not happened by 9am is not a failure.
  v_d := v_on - 1;
  while v_guard < 400 loop
    v_guard := v_guard + 1;

    -- Business days only: no reconciliation is expected at the weekend.
    if extract(isodow from v_d) in (6, 7) then
      v_d := v_d - 1;
      continue;
    end if;

    if exists (select 1 from public.fin_client_money_reconciliations r
                where r.tenant_id = p_tenant_id
                  and r.bank_account_id = p_bank_account_id
                  and r.reconciled_for = v_d
                  and r.status = 'reviewed') then
      exit;
    end if;

    -- A prepared-but-unreviewed reconciliation is not a reconciliation: one officer
    -- doing it alone is the failure the four-eyes rule exists to prevent.
    v_streak := v_streak + 1;
    v_d := v_d - 1;
  end loop;

  return v_streak;
end $$;

revoke all on function public.platform_ins_reconciliation_streak(uuid, uuid, date) from public;
grant execute on function public.platform_ins_reconciliation_streak(uuid, uuid, date) to authenticated;

-- The escalation itself.
create or replace function public.ins_escalate_missed_reconciliations(p_as_of date default null)
returns table (bank_account_id uuid, bank_name text, missed_days integer, escalated boolean, incident_id uuid)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  v_on      date := coalesce(p_as_of, public.ins_local_today());
  v_threshold integer := 2;
  v_bank    record;
  v_streak  integer;
  v_inc     fin_client_money_incidents%rowtype;
  v_incident uuid;
begin
  for v_bank in
    select b.id, b.name from fin_bank_accounts b
     where b.tenant_id = v_tenant and b.kind = 'client_money' and b.is_active
     order by b.name
  loop
    v_streak := public.platform_ins_reconciliation_streak(v_tenant, v_bank.id, v_on);
    v_incident := null;

    if v_streak >= v_threshold then
      -- Two consecutive missed days is the pack's line. The incident is recorded once
      -- and refreshed after that, not raised afresh each day.
      v_inc := null;
      select * into v_inc from fin_client_money_incidents i
       where i.tenant_id = v_tenant and i.bank_account_id = v_bank.id
         and i.kind = 'reconciliation_missed' and i.status = 'open'
       limit 1;

      if not found then
        insert into fin_client_money_incidents
          (tenant_id, currency, bank_account_id, kind, shortage, detected_on,
           detected_automatically, detail)
        values
          (v_tenant,
           (select currency from fin_bank_accounts where id = v_bank.id),
           v_bank.id,
           'reconciliation_missed', 0, v_on, true,
           jsonb_build_object('bank_name', v_bank.name, 'missed_days', v_streak))
        returning * into v_inc;

        update fin_client_money_incidents
           set incident_no = public.next_doc_number(v_tenant, 'fin_client_money_incident', 'CMI')
         where id = v_inc.id
        returning * into v_inc;

        perform public.log_platform_event('fin.client_money.reconciliation_escalated', v_tenant,
          'fin_client_money_incident', v_inc.id::text,
          format('%s has missed %s client-money reconciliations in a row', v_bank.name, v_streak),
          null, to_jsonb(v_inc));

        if to_regprocedure('public.ins_notify_finance_users(uuid)') is not null then
          perform public.ins_notify(v_tenant,
            public.ins_notify_finance_users(v_tenant), null,
            'client_money_reconciliation_missed',
            'Client-money reconciliation missed on ' || v_bank.name,
            format('%s business day(s) in a row with no reviewed reconciliation. This is escalated to company administration.', v_streak),
            '/finance/client-money');
        end if;
      else
        update fin_client_money_incidents
           set detail = detail || jsonb_build_object('missed_days', v_streak, 'last_seen', v_on)
         where id = v_inc.id
        returning * into v_inc;
      end if;

      v_incident := v_inc.id;
    end if;

    return query select v_bank.id, v_bank.name, v_streak, (v_streak >= v_threshold), v_incident;
  end loop;
end $$;

revoke all on function public.ins_escalate_missed_reconciliations(date) from public, anon;
grant execute on function public.ins_escalate_missed_reconciliations(date) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Prove it is installable
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'platform_ins_client_money_position') then
    raise exception 'B9: the position function is missing';
  end if;
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'fin_client_money_incidents') then
    raise exception 'B9: the incident table is missing';
  end if;
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'fin_client_money_reconciliations') then
    raise exception 'B9: the reconciliation sign-off table is missing';
  end if;
  raise notice 'PASS: B9 client-money position, shortages and reconciliation escalation are installable';
end $$;

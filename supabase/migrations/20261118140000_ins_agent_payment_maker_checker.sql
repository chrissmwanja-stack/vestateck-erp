-- =====================================================================
-- Insurance: agent commission payments get maker-checker (item 8, bit 4)
-- =====================================================================
--
-- The gap
-- -------
-- Every other money movement in this module separates the person who prepares
-- from the person who releases it. WHT remittances do it (prepared_by, then
-- ins_wht_approve_remittance by somebody else, refusal INS_WHT_SELF_APPROVAL).
-- Agent commission payment did not: ins_agent_commission_pay checked
-- can_manage_insurance() and paid, so one manager could raise a share, mark it
-- eligible and release the cash unaccompanied.
--
-- That is a real control failure rather than a missing convenience. An agent
-- payment is cash out of the door to a party the preparer may control, and it
-- is computed from a share the preparer may themself have configured through
-- ins_intermediary_terms. One pair of hands on all of it is how a fictitious
-- sub-agent gets paid.
--
-- The design
-- ----------
-- Three states instead of one, on the payment itself:
--
--   (nothing)    -> prepare  : somebody proposes a payment, stating the date,
--                              the bank account and the figure it will pay
--   prepared     -> approve  : a DIFFERENT manager accepts that proposal
--   approved     -> pay      : the cash leaves, posting the journals
--
-- The figure is frozen at prepare. Approval is of a NUMBER, not of an intention:
-- if the share changes between preparing and paying (a reversal, an eligibility
-- rollback), the approval no longer describes what would be paid and the payment
-- is refused rather than released at a figure nobody approved.
--
-- Why not reuse the accrual row for this
-- --------------------------------------
-- The status column on ins_agent_commission_accruals is the share's LIFECYCLE
-- (accrued -> eligible -> paid -> reversed), which is a statement about whether
-- the agent is owed the money. Whether a payment has been authorised is a
-- different question with a different answer, and folding it into the same
-- column would make 'eligible' ambiguous: eligible by the settlement rules, or
-- eligible and approved for release? The agent can see the first question;
-- management owns the second.
--
-- Idempotent: add-columns are if not exists, functions create-or-replace, and the
-- guard constraint is dropped and re-added under a name this file owns.
--
-- Applied migrations are never edited (MIGRATION_POLICY.md rule 9): this is a new
-- file and 20261118120000 is left alone.

-- ---------------------------------------------------------------------
-- 1. What a prepared payment is
-- ---------------------------------------------------------------------
-- Amount and net are stored because they are what the approver agreed to. A
-- prepared payment whose figures are recomputed at release time is not an
-- approved payment, it is an approved promise.
create table if not exists public.ins_agent_commission_payments (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenants(id) on delete cascade,
  accrual_id           uuid not null,
  bank_account_id      uuid not null references public.fin_bank_accounts(id) on delete restrict,
  currency             text not null,
  -- The gross share at the moment of preparing. The approver is agreeing to this.
  gross_amount         numeric(14,2) not null,
  -- The withholding that will be deducted, and the net the agent receives.
  wht_amount           numeric(14,2) not null default 0,
  -- The approved rate, its character and the parameter row they came from, frozen
  -- with the figure. The accrual copies them at release so the row that reports
  -- the tax names the law it was withheld under.
  wht_rate_pct         numeric(7,4),
  wht_is_final         boolean,
  wht_parameter_ref    uuid,
  net_amount           numeric(14,2) not null,
  paid_on              date not null,
  note                 text,
  status               text not null default 'prepared',
  prepared_by          uuid not null,
  prepared_at          timestamptz not null default now(),
  approved_by          uuid,
  approved_at          timestamptz,
  payment_journal_entry_id uuid references public.journal_entries(id),
  constraint ins_agent_payments_status_check
    check (status in ('prepared', 'approved', 'paid', 'rejected', 'cancelled')),
  constraint ins_agent_payments_gross_check check (gross_amount > 0),
  constraint ins_agent_payments_wht_check check (wht_amount >= 0 and wht_amount <= gross_amount),
  constraint ins_agent_payments_net_check check (net_amount = gross_amount - wht_amount),
  -- An approved or paid payment names its approver and the moment of approval.
  constraint ins_agent_payments_approved_check
    check ((status in ('prepared', 'rejected', 'cancelled'))
           or (approved_by is not null and approved_at is not null)),
  -- A paid payment names its journal.
  constraint ins_agent_payments_paid_check
    check ((status <> 'paid') = (payment_journal_entry_id is null)),
  -- One live payment per accrual: a share cannot be queued for payment twice.
  -- Rejected and cancelled rows are excluded so a proposal can be remade after a
  -- manager declines it, which is the whole point of being able to decline.
  constraint ins_agent_payments_tenant_id_key unique (tenant_id, id)
);

create unique index if not exists ins_agent_payments_live_once_key
  on public.ins_agent_commission_payments (tenant_id, accrual_id)
  where status not in ('rejected', 'cancelled');

create index if not exists ins_agent_payments_status_idx
  on public.ins_agent_commission_payments (tenant_id, status, prepared_at desc);

-- The accrual must belong to the same tenant. A plain FK on accrual_id would let
-- a hand-crafted insert point at another tenant's share, so the composite key is
-- the guard.
alter table public.ins_agent_commission_payments
  drop constraint if exists ins_agent_payments_accrual_fk;
alter table public.ins_agent_commission_payments
  add constraint ins_agent_payments_accrual_fk
  foreign key (tenant_id, accrual_id)
  references public.ins_agent_commission_accruals (tenant_id, id) on delete restrict;

comment on table public.ins_agent_commission_payments is
  'One authorised attempt to pay an agent share. prepared_by proposes a figure; approved_by (somebody else) accepts it; paying it posts the cash. The share itself stays on ins_agent_commission_accruals -- this is the authorisation around it, not a second ledger.';

comment on column public.ins_agent_commission_payments.gross_amount is
  'The share at the moment of preparing. Stored, not read back from the accrual at payment time, because the approver agreed to this number and it must not move under them.';

-- ---------------------------------------------------------------------
-- 2. The event log learns the authorisation steps
-- ---------------------------------------------------------------------
-- ins_agent_commission_events has a closed list of event kinds, which is right:
-- an open text column there would fill with typos nobody can report on. The
-- authorisation steps are new facts about a share, so the list is extended to
-- name them rather than reusing one of the four lifecycle kinds for something
-- that is not a lifecycle step.
--
--   prepared        somebody proposed a payment for this share
--   approved        a second person accepted that proposal
--   payment_declined  a proposal was declined, with the reason
--
-- `paid` and `reversed` keep their meaning: money moved, and the share was undone.
alter table public.ins_agent_commission_events
  drop constraint if exists ins_agent_commission_events_event_check;
alter table public.ins_agent_commission_events
  add constraint ins_agent_commission_events_event_check check (
    event in ('accrued', 'eligible', 'paid', 'reversed',
              'prepared', 'approved', 'payment_declined'));

-- ---------------------------------------------------------------------
-- 3. The maker cannot be the checker
-- ---------------------------------------------------------------------
-- Enforced in the table as well as in the function. A rule that lives only in the
-- RPC is one a service_role script or a future function can walk around; the
-- constraint makes the invariant a fact about the row.
alter table public.ins_agent_commission_payments
  drop constraint if exists ins_agent_payments_no_self_approval_chk;
alter table public.ins_agent_commission_payments
  add constraint ins_agent_payments_no_self_approval_chk
  check (approved_by is null or approved_by <> prepared_by);

-- ---------------------------------------------------------------------
-- 3. Guard: what may change, and when
-- ---------------------------------------------------------------------
-- The figures and the approver are written once. Re-preparing a declined payment
-- is a new row, not an edit, so the history of who wanted what stays readable.
create or replace function public.ins_agent_commission_payments_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_op = 'DELETE' then
    -- A payment that reached approval is evidence. Deleting it would erase who
    -- authorised what.
    if old.status in ('approved', 'paid') then
      raise exception 'INS_AGENT_PAYMENT_KEEP: a payment that was approved or paid cannot be deleted; it is the record of who authorised it'
        using errcode = '42501';
    end if;
    return old;
  end if;

  if new.accrual_id <> old.accrual_id
     or new.tenant_id <> old.tenant_id
     or new.bank_account_id <> old.bank_account_id then
    raise exception 'INS_AGENT_PAYMENT_IMMUTABLE: a prepared payment cannot be pointed at a different share, company or bank account. Cancel it and prepare a new one, so the history says what was actually proposed'
      using errcode = '42501';
  end if;

  if new.gross_amount <> old.gross_amount
     or new.wht_amount <> old.wht_amount
     or new.net_amount <> old.net_amount
     or new.paid_on <> old.paid_on then
    raise exception 'INS_AGENT_PAYMENT_IMMUTABLE: the amount, the withholding and the payment date are what the approver agreed to. They cannot be edited after preparing; cancel and prepare again'
      using errcode = '42501';
  end if;

  if old.status = 'paid' and new.status <> 'paid' then
    raise exception 'INS_AGENT_PAYMENT_PAID: this payment has been released to the agent; it cannot move back to %', new.status;
  end if;

  if old.status = 'rejected' and new.status <> 'rejected' then
    raise exception 'INS_AGENT_PAYMENT_REJECTED: a declined payment stays declined; prepare a new one';
  end if;

  return new;
end;
$function$;

revoke all on function public.ins_agent_commission_payments_guard() from public, anon, authenticated;

drop trigger if exists ins_agent_commission_payments_guard_trg on public.ins_agent_commission_payments;
create trigger ins_agent_commission_payments_guard_trg
  before update or delete on public.ins_agent_commission_payments
  for each row execute function public.ins_agent_commission_payments_guard();

-- ---------------------------------------------------------------------
-- 4. RLS: the tenant sees its own, and only insurance users see any
-- ---------------------------------------------------------------------
alter table public.ins_agent_commission_payments enable row level security;

drop policy if exists ins_agent_payments_select on public.ins_agent_commission_payments;
create policy ins_agent_payments_select on public.ins_agent_commission_payments
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

-- Writes go through the RPCs only. No insert/update/delete policies at all, so a
-- client cannot create an approved payment by hand -- the same shape the accruals
-- and events tables use.

-- The row the rest of the module uses to stop writes while a company is read-only
-- (unpaid subscription, closed period). Checked by test_tenant_read_only_guard and
-- by the live drift check, which fail if a new tenant table is added without it.
-- Named exactly `tenant_read_only_guard`, like every other tenant table: the guard
-- checks look the trigger up by name, not by function.
drop trigger if exists tenant_read_only_guard on public.ins_agent_commission_payments;
create trigger tenant_read_only_guard
  before insert or update or delete on public.ins_agent_commission_payments
  for each row execute function public.tenant_read_only_guard();

-- ---------------------------------------------------------------------
-- 6. Prepare
-- ---------------------------------------------------------------------
create or replace function public.ins_agent_commission_prepare_payment(
  p_accrual_id      uuid,
  p_bank_account_id uuid,
  p_paid_on         date,
  p_note            text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_uid    uuid := auth.uid();
  x        public.ins_agent_commission_accruals;
  a        public.ins_intermediaries;
  p        public.ins_policies;
  v_wht    jsonb;
  v_tax    numeric := 0;
  v_net    numeric;
  v_id     uuid;
  v_bank   uuid;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_paid_on is null then
    raise exception 'INS_AGENT_PAYMENT_DATE: a payment needs a date';
  end if;

  select * into x from public.ins_agent_commission_accruals
   where id = p_accrual_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_AGENT_ACCRUAL_NOT_FOUND'; end if;

  if x.status = 'paid' then
    raise exception 'INS_AGENT_ALREADY_PAID: this share has already been paid';
  end if;
  if x.status = 'reversed' then
    raise exception 'INS_AGENT_ACCRUAL_REVERSED: this accrual was reversed (%); it cannot be paid',
      coalesce(x.reversal_reason, 'no reason recorded');
  end if;
  if x.status = 'accrued' then
    raise exception 'INS_AGENT_NOT_ELIGIBLE: the share is accrued but not yet eligible. Mark it eligible once the brokerage''s commission on the policy is earned';
  end if;

  -- The same compliance stops a payment has always had, applied at prepare so the
  -- approver is not asked to authorise a payment that can never be released.
  -- Paying re-checks all of them against the payment date, because an agent can
  -- be suspended or a licence expire between preparing and paying.
  select * into a from public.ins_intermediaries
   where id = x.intermediary_id and tenant_id = v_tenant;
  if a.status <> 'active' then
    raise exception 'INS_AGENT_NOT_ACTIVE: % is %; a share cannot be paid to an intermediary that is not active',
      a.name, a.status;
  end if;
  if a.licence_valid_to is not null and a.licence_valid_to < p_paid_on then
    raise exception 'INS_AGENT_LICENCE_EXPIRED: %''s licence expired on %, before the payment date %',
      a.name, a.licence_valid_to, p_paid_on;
  end if;

  select bank.gl_account_id into v_bank
    from public.fin_bank_accounts bank
   where bank.id = p_bank_account_id and bank.tenant_id = v_tenant and bank.is_active;
  if v_bank is null then
    raise exception 'INS_BANK_ACCOUNT_NOT_FOUND: bank account % is not an active account on this company', p_bank_account_id;
  end if;

  select * into p from public.ins_policies
   where id = x.policy_id and tenant_id = v_tenant;

  -- The tax is determined for the date the money will leave, and frozen here so
  -- the approver sees the real net rather than a gross they must trust somebody
  -- else to reduce later.
  v_wht := public.ins_agent_wht_for(p_paid_on);
  v_tax := round(x.gross_amount * (v_wht ->> 'rate_pct')::numeric / 100.0, 2);
  if v_tax > x.gross_amount then
    raise exception 'INS_AGENT_WHT_EXCEEDS: withholding of % exceeds the gross share of %; the approved rate cannot be right', v_tax, x.gross_amount;
  end if;
  v_net := round(x.gross_amount - v_tax, 2);

  insert into public.ins_agent_commission_payments
    (tenant_id, accrual_id, bank_account_id, currency, gross_amount, wht_amount,
     wht_rate_pct, wht_is_final, wht_parameter_ref,
     net_amount, paid_on, note, status, prepared_by)
  values
    (v_tenant, x.id, p_bank_account_id, x.currency, x.gross_amount, v_tax,
     (v_wht ->> 'rate_pct')::numeric, (v_wht ->> 'is_final')::boolean,
     (v_wht ->> 'parameter_id')::uuid,
     v_net, p_paid_on, nullif(btrim(coalesce(p_note, '')), ''), 'prepared', v_uid)
  returning id into v_id;

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, note)
  values (v_tenant, x.id, 'prepared', v_net,
          format('payment of %s proposed for %s by %s', v_net, p_paid_on, coalesce(a.name, 'the agent')));

  return jsonb_build_object(
    'prepared', true,
    'payment_id', v_id,
    'accrual_id', x.id,
    'gross_amount', x.gross_amount,
    'wht_amount', v_tax,
    'wht_rate_pct', (v_wht ->> 'rate_pct')::numeric,
    'wht_is_final', (v_wht ->> 'is_final')::boolean,
    'net_amount', v_net,
    'paid_on', p_paid_on,
    'status', 'prepared',
    'awaiting_approval_by', 'somebody other than the preparer');
end
$function$;

revoke all on function public.ins_agent_commission_prepare_payment(uuid, uuid, date, text) from public, anon;
grant execute on function public.ins_agent_commission_prepare_payment(uuid, uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 7. Approve, decline, cancel
-- ---------------------------------------------------------------------
create or replace function public.ins_agent_commission_approve_payment(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_uid    uuid := auth.uid();
  y        public.ins_agent_commission_payments;
  x        public.ins_agent_commission_accruals;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into y from public.ins_agent_commission_payments
   where id = p_payment_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_AGENT_PAYMENT_NOT_FOUND'; end if;

  if y.status = 'approved' then
    return jsonb_build_object('approved', false, 'already_approved', true, 'payment_id', y.id);
  end if;
  if y.status <> 'prepared' then
    raise exception 'INS_AGENT_PAYMENT_NOT_PREPARED: only a prepared payment can be approved (this one is %)', y.status;
  end if;
  if y.prepared_by is not distinct from v_uid then
    raise exception 'INS_AGENT_SELF_APPROVAL: the person who prepared this payment cannot approve it. It is cash to a third party, and the preparer may be the person who configured the agent''s terms';
  end if;

  -- The share must still be the thing that was approved. A reversal, or the share
  -- being paid by some other route, makes the proposal stale: approving it would
  -- authorise a payment the ledger will then refuse, and the approver would have
  -- signed off on a number that no longer exists.
  select * into x from public.ins_agent_commission_accruals
   where id = y.accrual_id and tenant_id = v_tenant;
  if x.status <> 'eligible' then
    raise exception 'INS_AGENT_PAYMENT_STALE: the share is now % and no longer eligible, so this proposal no longer describes a payment that can be made. Cancel it and prepare a new one', x.status;
  end if;
  if x.gross_amount <> y.gross_amount then
    raise exception 'INS_AGENT_PAYMENT_STALE: the share was % when this payment was prepared and is % now. Cancel it and prepare a new one', y.gross_amount, x.gross_amount;
  end if;

  update public.ins_agent_commission_payments
     set status = 'approved', approved_by = v_uid, approved_at = now()
   where id = y.id;

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, note)
  values (v_tenant, y.accrual_id, 'approved', y.net_amount,
          format('payment of %s approved for release', y.net_amount));

  return jsonb_build_object('approved', true, 'payment_id', y.id,
                            'net_amount', y.net_amount, 'status', 'approved');
end
$function$;

revoke all on function public.ins_agent_commission_approve_payment(uuid) from public, anon;
grant execute on function public.ins_agent_commission_approve_payment(uuid) to authenticated;

-- Declining is not approving-by-other-means: it closes the proposal so a new one
-- can be made, and it keeps who declined it and why.
create or replace function public.ins_agent_commission_reject_payment(p_payment_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_uid    uuid := auth.uid();
  y        public.ins_agent_commission_payments;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'INS_AGENT_PAYMENT_REJECT_REASON: declining a payment needs a reason of at least 10 characters; it is what the person who proposed it reads';
  end if;

  select * into y from public.ins_agent_commission_payments
   where id = p_payment_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_AGENT_PAYMENT_NOT_FOUND'; end if;
  if y.status in ('approved', 'paid') then
    raise exception 'INS_AGENT_PAYMENT_DECIDED: this payment is % and cannot be declined. A release that has been authorised is undone by reversing the share, not by rewriting the authorisation', y.status;
  end if;
  if y.status = 'rejected' then
    return jsonb_build_object('rejected', false, 'already_rejected', true, 'payment_id', y.id);
  end if;

  update public.ins_agent_commission_payments
     set status = 'rejected', approved_by = null, approved_at = null,
         note = concat_ws(E'\n', note, 'Declined: ' || btrim(p_reason))
   where id = y.id;

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, note)
  values (v_tenant, y.accrual_id, 'payment_declined', y.net_amount, btrim(p_reason));

  return jsonb_build_object('rejected', true, 'payment_id', y.id, 'status', 'rejected');
end
$function$;

revoke all on function public.ins_agent_commission_reject_payment(uuid, text) from public, anon;
grant execute on function public.ins_agent_commission_reject_payment(uuid, text) to authenticated;

-- The preparer may withdraw their own proposal before anybody has decided on it.
create or replace function public.ins_agent_commission_cancel_payment(p_payment_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_uid    uuid := auth.uid();
  y        public.ins_agent_commission_payments;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into y from public.ins_agent_commission_payments
   where id = p_payment_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_AGENT_PAYMENT_NOT_FOUND'; end if;
  if y.prepared_by is distinct from v_uid then
    raise exception 'INS_AGENT_PAYMENT_NOT_YOURS: only the person who prepared a payment may withdraw it; anybody else declines it, so the record says who stopped it';
  end if;
  if y.status <> 'prepared' then
    raise exception 'INS_AGENT_PAYMENT_NOT_PREPARED: a payment that is % cannot be withdrawn', y.status;
  end if;

  update public.ins_agent_commission_payments
     set status = 'cancelled'
   where id = y.id;

  return jsonb_build_object('cancelled', true, 'payment_id', y.id);
end
$function$;

revoke all on function public.ins_agent_commission_cancel_payment(uuid, text) from public, anon;
grant execute on function public.ins_agent_commission_cancel_payment(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 8. Pay: the old signature, now gated on an approved payment
-- ---------------------------------------------------------------------
-- The four-argument form is kept so nothing that calls it breaks, but it is no
-- longer a way to pay: it now requires an approved payment for that share, and
-- refuses otherwise. A caller that used to pay directly must prepare and approve
-- first. That is the point of the change.
create or replace function public.ins_agent_commission_pay(
  p_accrual_id      uuid,
  p_bank_account_id uuid,
  p_paid_on         date,
  p_note            text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  y        public.ins_agent_commission_payments;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into y from public.ins_agent_commission_payments
   where tenant_id = v_tenant and accrual_id = p_accrual_id
     and status in ('approved', 'paid')
   order by prepared_at desc
   limit 1;

  if not found then
    raise exception 'INS_AGENT_PAYMENT_NOT_APPROVED: this share has no approved payment. Prepare the payment, have somebody else approve it, then release it -- one person cannot do all three';
  end if;

  return public.ins_agent_commission_release_payment(y.id, p_note);
end
$function$;

revoke all on function public.ins_agent_commission_pay(uuid, uuid, date, text) from public, anon;
grant execute on function public.ins_agent_commission_pay(uuid, uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 9. Release: the actual cash, against an approved payment
-- ---------------------------------------------------------------------
create or replace function public.ins_agent_commission_release_payment(
  p_payment_id uuid,
  p_note       text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  y        public.ins_agent_commission_payments;
  x        public.ins_agent_commission_accruals;
  a        public.ins_intermediaries;
  p        public.ins_policies;
  v_ap     uuid;
  v_bank   uuid;
  v_tax    numeric;
  v_wht_gl uuid;
  v_lines  jsonb;
  v_je     public.journal_entries;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into y from public.ins_agent_commission_payments
   where id = p_payment_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_AGENT_PAYMENT_NOT_FOUND'; end if;

  if y.status = 'paid' then
    return jsonb_build_object('paid', false, 'already_paid', true, 'payment_id', y.id,
                              'paid_at', y.paid_on);
  end if;
  if y.status <> 'approved' then
    raise exception 'INS_AGENT_PAYMENT_NOT_APPROVED: this payment is %. Only an approved payment can be released', y.status;
  end if;

  select * into x from public.ins_agent_commission_accruals
   where id = y.accrual_id and tenant_id = v_tenant
   for update;
  if x.status <> 'eligible' then
    raise exception 'INS_AGENT_PAYMENT_STALE: the share is now % and can no longer be paid', x.status;
  end if;

  -- Re-checked against the PAYMENT date, not the day the proposal was made: an
  -- agent suspended or a licence expired between approval and release stops the
  -- cash, which is exactly the window maker-checker opens up.
  select * into a from public.ins_intermediaries
   where id = x.intermediary_id and tenant_id = v_tenant;
  if a.status <> 'active' then
    raise exception 'INS_AGENT_NOT_ACTIVE: % is %; a share cannot be paid to an intermediary that is not active',
      a.name, a.status;
  end if;
  if a.licence_valid_to is not null and a.licence_valid_to < y.paid_on then
    raise exception 'INS_AGENT_LICENCE_EXPIRED: %''s licence expired on %, before the payment date %',
      a.name, a.licence_valid_to, y.paid_on;
  end if;

  select * into p from public.ins_policies
   where id = x.policy_id and tenant_id = v_tenant;

  v_tax := y.wht_amount;

  v_ap := public.get_posting_account(v_tenant, 'ap_control');
  if v_ap is null then
    raise exception 'INS_POSTING_RULE_MISSING: paying an agent share needs the ap_control posting rule';
  end if;
  select bank.gl_account_id into v_bank
    from public.fin_bank_accounts bank
   where bank.id = y.bank_account_id and bank.tenant_id = v_tenant and bank.is_active;
  if v_bank is null then
    raise exception 'INS_BANK_ACCOUNT_NOT_FOUND: bank account % is not an active account on this company', y.bank_account_id;
  end if;

  -- The accrual credited the payable at the GROSS; the withholding is taken from
  -- it here, at the payment, because that is when s.134 bites.
  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ap,   'debit',  y.gross_amount,
                       'currency', y.currency,
                       'description', 'Clear agent payable for ' || p.policy_no),
    jsonb_build_object('gl_account_id', v_bank, 'credit', y.net_amount,
                       'currency', y.currency,
                       'description', 'Paid to ' || a.name));

  if v_tax > 0 then
    v_wht_gl := public.get_posting_account(v_tenant, 'wht_payable');
    if v_wht_gl is null then
      raise exception 'INS_POSTING_RULE_MISSING: withholding tax on agent commission needs the wht_payable posting rule. It cannot be withheld without an account to hold it, or the agent is short and URA is unrecorded';
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'gl_account_id', v_wht_gl, 'credit', v_tax,
      'currency', y.currency,
      'description', 'WHT withheld on ' || p.policy_no || ' for remittance to URA'));
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'ins_agent_commission_payment', x.id, y.paid_on,
    'Agent commission paid to ' || a.name || ' for ' || p.policy_no,
    v_lines);

  -- The rate, the character and the parameter that produced them were resolved
  -- and frozen when the payment was prepared, so they are read from the payment
  -- rather than resolved a second time here. Resolving again at release would let
  -- a rate approved between preparing and paying change what was withheld from a
  -- figure two people had already agreed.
  perform set_config('ins.via_wht_calc', 'on', true);
  update public.ins_agent_commission_accruals
     set status = 'paid', paid_at = now(), paid_on = y.paid_on,
         payment_journal_entry_id = v_je.id,
         wht_amount = v_tax,
         net_amount = y.net_amount,
         wht_rate_pct = y.wht_rate_pct,
         wht_is_final = y.wht_is_final,
         wht_parameter_ref = y.wht_parameter_ref,
         updated_at = now()
   where id = x.id;
  perform set_config('ins.via_wht_calc', 'off', true);

  update public.ins_agent_commission_payments
     set status = 'paid', payment_journal_entry_id = v_je.id
   where id = y.id;

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, journal_entry_id, note)
  values (v_tenant, x.id, 'paid', y.net_amount, v_je.id,
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object('paid', true, 'payment_id', y.id, 'accrual_id', x.id,
                            'amount', y.net_amount, 'gross_amount', y.gross_amount,
                            'wht_amount', v_tax,
                            'wht_on', y.paid_on,
                            'journal_entry_id', v_je.id);
end
$function$;

revoke all on function public.ins_agent_commission_release_payment(uuid, text) from public, anon;
grant execute on function public.ins_agent_commission_release_payment(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 10. What a tenant still has to pay, and what is waiting on a second pair of eyes
-- ---------------------------------------------------------------------
create or replace function public.ins_agent_payment_position()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_out    jsonb;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'prepared_count',  count(*) filter (where status = 'prepared'),
    'prepared_total',  coalesce(sum(net_amount) filter (where status = 'prepared'), 0),
    'approved_count',  count(*) filter (where status = 'approved'),
    'approved_total',  coalesce(sum(net_amount) filter (where status = 'approved'), 0),
    'paid_total',      coalesce(sum(net_amount) filter (where status = 'paid'), 0),
    'rejected_count',  count(*) filter (where status = 'rejected'))
    into v_out
    from public.ins_agent_commission_payments
   where tenant_id = v_tenant;

  return v_out;
end
$function$;

revoke all on function public.ins_agent_payment_position() from public, anon;
grant execute on function public.ins_agent_payment_position() to authenticated;

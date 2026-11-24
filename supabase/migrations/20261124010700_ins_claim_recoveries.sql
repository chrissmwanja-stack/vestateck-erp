-- =====================================================================
-- Claim recoveries
-- Accountant pack v2, B8; pack section 7.7
-- =====================================================================
-- The pack lists recoveries as covering "overpayments, third-party recoveries,
-- insurer underpayments, instalment recoveries, disputes and authorised
-- write-offs", and states one hard rule: a recovery never touches commission
-- accounts. Write-offs were built in 20261124010500. This builds the rest.
--
-- WHAT A RECOVERY IS
--
-- Money the brokerage expects back, or expects to receive, in connection with a
-- claim. It is deliberately NOT modelled as a negative claim:
--
--   * it may be owed by the insurer (underpayment), by a third party (subrogation),
--     or by the client (overpayment recovered);
--   * it is recovered independently of the claim's own settlement and often long
--     after it is closed;
--   * treating it as a negative claim would re-price the approved amount and disturb
--     every report that has already relied on it.
--
-- So a recovery is a separate receivable with its own open item, its own party and
-- its own life: raised, then either received (allocated through the normal cash
-- path) or written off as uncollectable (through the disposition primitive).
--
-- THE ACCOUNTING
--
--   raise      Dr 1100 AR control / Cr <recovery income account>
--   receive    Dr client money bank / Cr 1100 AR control   (ordinary receipt)
--   write off  Dr <recovery income account> / Cr 1100 AR control
--              (a disposition on the recovery item, kind
--               'claim_recovery_uncollectable')
--
-- The credit account at raise is a choice, exactly as with claim write-offs, so the
-- caller must name it: a real, non-control account of the company. The code refuses
-- commission accounts by name (4000 / 2020 / 1110) because the pack says a recovery
-- never touches them. Which account it actually is -- recovery income, an expense
-- contra, or netted against the loss -- is the accountant's call and is Q4 in the
-- pack's Appendix B.
--
-- WHY THE PARTY IS SEPARATE FROM THE CLAIM'S CLIENT
--
-- An overpayment is recovered from the claimant; an underpayment from the insurer.
-- Those are different accounts, and using the client's AR for an insurer recovery
-- would make the client statement show money they never owed. The recovery names its
-- own payer explicitly.

-- ---------------------------------------------------------------------
-- 1. The recovery record
-- ---------------------------------------------------------------------
create table if not exists ins_claim_recoveries (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  recovery_no       text not null,
  claim_id          uuid not null references ins_claims(id) on delete restrict,
  kind              text not null check (kind in (
                      'insurer_underpayment', 'third_party', 'overpayment',
                      'instalment', 'other')),
  payer_party_account_id uuid not null references accounts(id),
  amount            numeric not null check (amount > 0),
  currency          char(3) not null,
  raised_on         date not null,
  status            text not null default 'outstanding'
                    check (status in ('outstanding', 'partly_received', 'received', 'written_off')),
  received_amount   numeric not null default 0 check (received_amount >= 0),
  written_off_amount numeric not null default 0 check (written_off_amount >= 0),
  open_item_id      uuid,
  journal_entry_id  uuid,
  credit_gl_account_id uuid not null,
  reason            text not null,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint ins_claim_recoveries_reason_check check (length(btrim(reason)) >= 5),
  constraint ins_claim_recoveries_not_over
    check (received_amount + written_off_amount <= amount),
  constraint ins_claim_recoveries_no_check unique (tenant_id, recovery_no)
);

create index if not exists ins_claim_recoveries_claim_idx
  on ins_claim_recoveries (tenant_id, claim_id, status);
create index if not exists ins_claim_recoveries_payer_idx
  on ins_claim_recoveries (tenant_id, payer_party_account_id);

alter table ins_claim_recoveries enable row level security;

drop policy if exists ins_claim_recoveries_read on ins_claim_recoveries;
create policy ins_claim_recoveries_read on ins_claim_recoveries
  for select to authenticated using (tenant_id = get_my_tenant_id());

revoke insert, update, delete on ins_claim_recoveries from authenticated, anon;

comment on column ins_claim_recoveries.credit_gl_account_id is
  'The account the recovery was credited to when raised; the write-off charges the loss back to the same account. Stored rather than derived so the pair can be reviewed together.';

comment on table ins_claim_recoveries is
  'Pack v2 section 7.7. A recovery is a separate receivable with its own payer, not a negative claim. Raised with ins_raise_claim_recovery, received through the ordinary cash path, written off through a claim_recovery_uncollectable disposition.';

-- ---------------------------------------------------------------------
-- 2. Raising a recovery
-- ---------------------------------------------------------------------
create or replace function public.ins_raise_claim_recovery(
  p_claim_id uuid,
  p_kind text,
  p_payer_party_account_id uuid,
  p_amount numeric,
  p_credit_gl_account_id uuid,
  p_reason text,
  p_raised_on date default null::date
) returns ins_claim_recoveries
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_ccy    text;
  v_gl     gl_accounts%rowtype;
  v_ar_gl  uuid;
  v_payer  accounts%rowtype;
  v_no     text;
  v_je     journal_entries%rowtype;
  v_item   fin_open_items%rowtype;
  v_row    ins_claim_recoveries%rowtype;
  v_forbidden uuid;
  v_date   date := coalesce(p_raised_on, current_date);
  v_desc   text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: raising a claim recovery needs insurance manager authority' using errcode = '42501';
  end if;
  if not is_finance_team_member('finance') then
    raise exception 'INS_RECOVERY_FINANCE: raising a claim recovery needs the finance role' using errcode = '42501';
  end if;

  if p_kind not in ('insurer_underpayment', 'third_party', 'overpayment', 'instalment', 'other') then
    raise exception 'INS_RECOVERY_KIND: unknown recovery kind %. Use insurer_underpayment, third_party, overpayment, instalment or other.', p_kind;
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_RECOVERY_AMOUNT: the recovery must be greater than zero';
  end if;
  if nullif(btrim(p_reason), '') is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_NOTE_REQUIRED: give the reason for the recovery';
  end if;
  if v_date > current_date + 1 then
    raise exception 'INS_RECOVERY_DATE: the recovery date cannot be in the future';
  end if;

  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  -- A claim carries no currency of its own: it is the policy's (as in claim recognition).
  select p.currency into v_ccy from ins_policies p where p.id = v_claim.policy_id;

  -- The payer must be a real account of this company. It is not defaulted to the
  -- claim's client: an insurer underpayment is not owed by the client.
  select * into v_payer from accounts
   where id = p_payer_party_account_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_RECOVERY_PAYER: account % is not an account of this company', p_payer_party_account_id;
  end if;

  select * into v_gl from gl_accounts
   where id = p_credit_gl_account_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_RECOVERY_ACCOUNT: account % is not a GL account of this company', p_credit_gl_account_id;
  end if;
  if v_gl.is_control_account then
    raise exception 'INS_RECOVERY_ACCOUNT: % is a control account; name the account the recovery income belongs in', v_gl.account_code;
  end if;
  -- Pack 7.7: a recovery never touches commission accounts.
  foreach v_forbidden in array array[
    get_posting_account(v_tenant, 'commission_income'),
    get_posting_account(v_tenant, 'unearned_commission'),
    get_posting_account(v_tenant, 'commission_receivable')]
  loop
    if v_forbidden is not null and v_forbidden = v_gl.id then
      raise exception 'INS_RECOVERY_COMMISSION: a claim recovery may not post to % -- recoveries never touch commission accounts',
        v_gl.account_code;
    end if;
  end loop;

  v_ar_gl := get_posting_account(v_tenant, 'ar_control');
  if v_ar_gl is null then
    raise exception 'INS_RECOVERY_ACCOUNT: this company has no ar_control posting rule';
  end if;

  perform set_config('ins.via_rpc', 'on', true);

  v_no := next_doc_number(v_tenant, 'ins_claim_recovery', 'REC');
  v_desc := 'Claim recovery ' || v_no || ' on ' || v_claim.claim_no;

  -- Dr AR / Cr the named account: money to come back in, with the credit landing
  -- where the policy says it should.
  v_je := public.post_journal_entry(
    v_tenant, 'ins_claim_recovery', v_claim.id, v_date, v_desc,
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_ar_gl, 'debit', p_amount,
                         'currency', v_ccy, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_gl.id, 'credit', p_amount,
                         'currency', v_ccy, 'description', v_desc)));

  insert into fin_open_items (
    tenant_id, party_account_id, side, control_role, source_type, source_id,
    document_no, document_date, due_date, currency, amount, description, created_by, journal_entry_id
  ) values (
    v_tenant, p_payer_party_account_id, 'receivable', 'ar_control', 'ins_claim_recovery', v_claim.id,
    v_no, v_date, v_date, v_ccy, p_amount, btrim(p_reason), auth.uid(), v_je.id
  )
  returning * into v_item;

  insert into ins_claim_recoveries (
    tenant_id, recovery_no, claim_id, kind, payer_party_account_id, amount, currency,
    raised_on, status, open_item_id, journal_entry_id, credit_gl_account_id, reason, created_by
  ) values (
    v_tenant, v_no, v_claim.id, p_kind, p_payer_party_account_id, p_amount, v_ccy,
    v_date, 'outstanding', v_item.id, v_je.id, p_credit_gl_account_id, btrim(p_reason), auth.uid()
  )
  returning * into v_row;

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_claim.id, v_claim.status, v_claim.status,
          'Recovery ' || v_no || ' raised (' || p_kind || '): ' || btrim(p_reason));

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Receiving a recovery
-- ---------------------------------------------------------------------
-- Receiving is an ordinary cash receipt against the recovery's open item, so the
-- existing settlement guards (client-money bank, currency, no over-allocation) all
-- apply. This function only locks the item to the recovery and keeps the recovery
-- row in step.
create or replace function public.ins_receive_claim_recovery(
  p_recovery_id uuid,
  p_bank_account_id uuid,
  p_amount numeric,
  p_received_on date,
  p_reference text default null::text,
  p_notes text default null::text
) returns ins_claim_recoveries
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_rec    ins_claim_recoveries%rowtype;
  v_item   fin_open_items%rowtype;
  v_open   numeric;
  v_set    fin_settlements%rowtype;
begin
  if not is_finance_team_member('finance') then
    raise exception 'INS_RECOVERY_FINANCE: receiving a recovery needs the finance role' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_RECOVERY_AMOUNT: the amount received must be greater than zero';
  end if;

  select * into v_rec from ins_claim_recoveries
   where id = p_recovery_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: recovery';
  end if;
  if v_rec.status = 'written_off' then
    raise exception 'INS_RECOVERY_WRITTEN_OFF: recovery % has been written off', v_rec.recovery_no;
  end if;

  select * into v_item from fin_open_items
   where id = v_rec.open_item_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_RECOVERY_ITEM: the open item for recovery % is missing', v_rec.recovery_no;
  end if;

  v_open := v_item.amount - public.fin_open_item_consumed(v_item.id);
  if p_amount > v_open then
    raise exception 'INS_RECOVERY_EXCEEDS: recovery % has % outstanding, % cannot be received',
      v_rec.recovery_no, v_open, p_amount;
  end if;

  v_set := public.platform_fin_record_settlement_impl(
    v_tenant, p_bank_account_id, 'in', v_item.party_account_id, p_amount, p_received_on,
    jsonb_build_array(jsonb_build_object('open_item_id', v_item.id, 'amount', p_amount)),
    coalesce(nullif(btrim(p_reference), ''), v_rec.recovery_no), p_notes);

  perform set_config('ins.via_rpc', 'on', true);
  update ins_claim_recoveries
     set received_amount = received_amount + p_amount,
         updated_at = now(),
         status = case when received_amount + p_amount + written_off_amount >= amount
                       then 'received' else 'partly_received' end
   where id = v_rec.id
  returning * into v_rec;

  return v_rec;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Writing a recovery off
-- ---------------------------------------------------------------------
create or replace function public.ins_write_off_claim_recovery(
  p_recovery_id uuid,
  p_amount numeric,
  p_reason text
) returns ins_claim_recoveries
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_rec    ins_claim_recoveries%rowtype;
  v_open   numeric;
  v_disp   fin_open_item_dispositions%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: writing off a recovery needs insurance manager authority' using errcode = '42501';
  end if;
  if not is_finance_team_member('finance') then
    raise exception 'INS_RECOVERY_FINANCE: writing off a recovery needs the finance role' using errcode = '42501';
  end if;

  select * into v_rec from ins_claim_recoveries
   where id = p_recovery_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: recovery';
  end if;

  v_open := public.fin_open_item_consumed(v_rec.open_item_id);
  if p_amount is null or p_amount <= 0
     or p_amount > v_rec.amount - v_rec.received_amount - v_rec.written_off_amount then
    raise exception 'INS_RECOVERY_EXCEEDS: recovery % has % available to write off',
      v_rec.recovery_no, v_rec.amount - v_rec.received_amount - v_rec.written_off_amount;
  end if;

  -- The loss goes back to the account the recovery was credited to when it was
  -- raised, which is stored on the row rather than guessed from the journal. There
  -- is deliberately no fallback to default_expense: a silent default here would be
  -- the software choosing which account absorbs a bad recovery, and that is the
  -- accountant's decision.
  v_disp := public.ins_dispose_open_item(
    v_rec.open_item_id, 'claim_recovery_uncollectable', p_amount,
    v_rec.credit_gl_account_id, p_reason, current_date);

  perform set_config('ins.via_rpc', 'on', true);
  update ins_claim_recoveries
     set written_off_amount = written_off_amount + p_amount,
         updated_at = now(),
         status = case when received_amount + written_off_amount + p_amount >= amount
                       then 'written_off' else status end
   where id = v_rec.id
  returning * into v_rec;

  return v_rec;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. A recovery cannot be quietly edited
-- ---------------------------------------------------------------------
create or replace function public.ins_claim_recoveries_guard() returns trigger
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'INS_RECOVERY_IMMUTABLE: recoveries are retained; write one off instead';
  end if;
  if tg_op = 'INSERT' and not public.ins_via_rpc() then
    raise exception 'INS_RPC_ONLY: raise a recovery with ins_raise_claim_recovery()' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    -- Only the running totals and status may move, and only from this module.
    if not public.ins_via_rpc() then
      raise exception 'INS_RECOVERY_RPC_ONLY: a recovery is updated through its receive and write-off functions' using errcode = '42501';
    end if;
    if (to_jsonb(new) - array['received_amount', 'written_off_amount', 'status', 'updated_at'])
       is distinct from
       (to_jsonb(old) - array['received_amount', 'written_off_amount', 'status', 'updated_at']) then
      raise exception 'INS_RECOVERY_IMMUTABLE: the claim, payer, amount and basis of a recovery cannot be changed';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ins_claim_recoveries_guard on ins_claim_recoveries;
create trigger trg_ins_claim_recoveries_guard
  before insert or update or delete on ins_claim_recoveries
  for each row execute function ins_claim_recoveries_guard();

-- ---------------------------------------------------------------------
-- 6. Exposure
-- ---------------------------------------------------------------------
revoke all on function public.ins_raise_claim_recovery(uuid, text, uuid, numeric, uuid, text, date) from public;
revoke all on function public.ins_receive_claim_recovery(uuid, uuid, numeric, date, text, text) from public;
revoke all on function public.ins_write_off_claim_recovery(uuid, numeric, text) from public;

grant execute on function public.ins_raise_claim_recovery(uuid, text, uuid, numeric, uuid, text, date) to authenticated;
grant execute on function public.ins_receive_claim_recovery(uuid, uuid, numeric, date, text, text) to authenticated;
grant execute on function public.ins_write_off_claim_recovery(uuid, numeric, text) to authenticated;

grant select on ins_claim_recoveries to authenticated;

comment on function public.ins_raise_claim_recovery(uuid, text, uuid, numeric, uuid, text, date) is
  'Raises a recovery as its own receivable with its own payer. The credit account is the accounting-policy choice and must be named; commission accounts are refused (pack v2 section 7.7).';

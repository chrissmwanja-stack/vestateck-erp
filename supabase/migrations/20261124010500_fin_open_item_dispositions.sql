-- =====================================================================
-- Non-cash party-balance movement: dispositions
-- Accountant pack v2, B11 (blocking production go-live)
-- =====================================================================
-- THE GAP THIS CLOSES
--
-- Until now a party balance could fall in exactly two ways:
--
--   1. cash        -- fin_allocations on a posted fin_settlements row, which always
--                     names a bank account and posts Dr bank / Cr control;
--   2. a same-role -- fin_credit_applications against a fin_credit_notes row, where
--      credit note    the note and the item must share side and control_role.
--
-- Neither can express the two movements the accountant pack needs:
--
--   * releasing a client advance:  Dr 2040 payable  / Cr 1100 receivable
--   * writing off a claim balance: Dr 2030 payable  / Cr expense
--
-- The first moves value between two control accounts. The second reduces a control
-- account with no counterparty control account at all. Both are non-cash, and the
-- subledger had no vocabulary for either. B2 worked around the first by refusing to
-- do it; B8's write-off half is blocked by the second. This migration supplies the
-- missing vocabulary rather than reshaping the two that already work.
--
-- WHAT IS ADDED
--
--   fin_open_item_dispositions  one row per non-cash movement of a party balance.
--                               KIND says what the movement IS, which is the
--                               accountant's decision, not the software's:
--                                 advance_release, advance_forfeit,
--                                 claim_write_off, claim_recovery_uncollectable
--                               Each row names the GL account it is measured
--                               against (the credit account for a write-off; the
--                               same account as the item for an advance release)
--                               and the journal that posted it.
--
--   fin_open_item_consumed()    now counts posted dispositions as a third source,
--                               so outstanding balances, the ageing view and
--                               every existing guard see the truth.
--   fin_open_item_balances      rebuilt from a shared aggregate so the view and the
--                               function can no longer disagree.
--
-- WHY THE ACCOUNT IS A PARAMETER AND NOT A CONSTANT
--
-- For an advance release the answer is forced by double entry: Dr 2040 / Cr AR.
-- For a write-off it is not. "Claim written off" could sit in an expense account,
-- a bad-debt account, or against the commission income it was never going to
-- produce -- and the pack does not say which. Choosing one here would be the
-- software inventing an accounting policy, which is the thing this pack exists to
-- prevent. So the caller must name the account, it must be a real account of the
-- company, and it must not be a control account (posting to a control account
-- without a subledger reference is what B6 forbids). Which account to use is
-- confirmed in the pack and recorded in Appendix B; this migration only makes it
-- expressible.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
-- It does not let anything post to a control account without a subledger item, it
-- does not move cash, and it does not bypass ins_advance_allocation_guard. A
-- disposition is journal + subledger row, atomically, or nothing.

-- ---------------------------------------------------------------------
-- 1. The disposition record
-- ---------------------------------------------------------------------
create table if not exists fin_open_item_dispositions (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  open_item_id      uuid not null,
  kind              text not null,
  amount            numeric not null check (amount > 0),
  currency          char(3) not null,
  counterparty_gl_account_id uuid not null,
  journal_entry_id  uuid not null,
  reason            text not null,
  party_account_id  uuid not null,
  control_role      text not null,
  side              text not null,
  source_type       text,
  source_id         uuid,
  accounting_policy_version integer not null default 1 check (accounting_policy_version >= 1),
  created_by        uuid,
  created_at        timestamptz not null default now(),
  constraint fin_open_item_dispositions_kind_check check (kind in (
    'advance_release', 'advance_forfeit',
    'claim_write_off', 'claim_recovery_uncollectable')),
  constraint fin_open_item_dispositions_reason_check check (length(btrim(reason)) >= 5),
  constraint fin_open_item_dispositions_item_fk
    foreign key (tenant_id, open_item_id) references fin_open_items (tenant_id, id),
  constraint fin_open_item_dispositions_journal_fk
    foreign key (journal_entry_id) references journal_entries (id),
  constraint fin_open_item_dispositions_gl_fk
    foreign key (counterparty_gl_account_id) references gl_accounts (id)
);

create index if not exists fin_open_item_dispositions_item_idx
  on fin_open_item_dispositions (tenant_id, open_item_id);
create index if not exists fin_open_item_dispositions_journal_idx
  on fin_open_item_dispositions (journal_entry_id);

alter table fin_open_item_dispositions enable row level security;

drop policy if exists fin_open_item_dispositions_read on fin_open_item_dispositions;
create policy fin_open_item_dispositions_read on fin_open_item_dispositions
  for select to authenticated using (tenant_id = get_my_tenant_id());

-- A financial record: written only through ins_dispose_open_item().
revoke insert, update, delete on fin_open_item_dispositions from authenticated, anon;

comment on table fin_open_item_dispositions is
  'Non-cash movement of a party balance: advance release/forfeit, claim write-off, uncollectable recovery. Counted by fin_open_item_consumed() alongside settlements and credit notes. Written only by ins_dispose_open_item().';

-- ---------------------------------------------------------------------
-- 2. One aggregate, used by both the function and the view
-- ---------------------------------------------------------------------
-- The view previously carried its own copy of the consumption arithmetic. Two
-- copies of a rule are two chances to disagree, so both now read this.
create or replace view public.fin_open_item_consumption_v
  with (security_invoker = 'true') as
  select i.id as open_item_id,
         i.tenant_id,
         coalesce(a.allocated, 0) as allocated_amount,
         coalesce(c.credited, 0) as credited_amount,
         coalesce(d.disposed, 0) as disposed_amount,
         coalesce(a.allocated, 0) + coalesce(c.credited, 0) + coalesce(d.disposed, 0) as consumed_amount
    from public.fin_open_items i
    left join lateral (
      select sum(al.amount) as allocated
        from public.fin_allocations al
        join public.fin_settlements s on s.id = al.settlement_id
       where al.open_item_id = i.id and s.status = 'posted'
    ) a on true
    left join lateral (
      select sum(ca.amount) as credited
        from public.fin_credit_applications ca
        join public.fin_credit_notes cn on cn.id = ca.credit_note_id
       where ca.open_item_id = i.id and cn.status = 'posted'
    ) c on true
    left join lateral (
      select sum(d.amount) as disposed
        from public.fin_open_item_dispositions d
        join public.journal_entries je on je.id = d.journal_entry_id
       where d.open_item_id = i.id and je.status = 'posted'
    ) d on true;

-- ---------------------------------------------------------------------
-- 3. fin_open_item_consumed(): the third source
-- ---------------------------------------------------------------------
create or replace function public.fin_open_item_consumed(p_open_item_id uuid) returns numeric
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select coalesce(consumed_amount, 0)
    from public.fin_open_item_consumption_v
   where open_item_id = p_open_item_id
$$;

comment on function public.fin_open_item_consumed(uuid) is
  'Total of an open item already consumed: posted settlement allocations + posted credit applications + posted dispositions. Every balance and guard reads this, so a new consumption source must be added here and nowhere else.';

-- ---------------------------------------------------------------------
-- 4. fin_open_item_balances: rebuilt on the same aggregate
-- ---------------------------------------------------------------------
create or replace view public.fin_open_item_balances
  with (security_invoker = 'true') as
  select i.id,
         i.tenant_id,
         i.party_account_id,
         i.side,
         i.control_role,
         i.source_type,
         i.source_id,
         i.document_no,
         i.document_date,
         i.due_date,
         i.currency,
         i.amount,
         i.description,
         coalesce(k.allocated_amount, 0) as allocated_amount,
         i.amount - coalesce(k.consumed_amount, 0) as outstanding_amount,
         case
           when coalesce(k.consumed_amount, 0) = 0 then 'open'
           when coalesce(k.consumed_amount, 0) < i.amount then 'partly_settled'
           else 'settled'
         end as settlement_status,
         coalesce(k.credited_amount, 0) as credited_amount,
         i.fx_rate,
         round((i.amount - coalesce(k.consumed_amount, 0)) * i.fx_rate, 2) as base_outstanding_amount,
         coalesce(k.disposed_amount, 0) as disposed_amount
    from public.fin_open_items i
    left join public.fin_open_item_consumption_v k on k.open_item_id = i.id;

-- ---------------------------------------------------------------------
-- 5. Writing a disposition
-- ---------------------------------------------------------------------
create or replace function public.ins_dispose_open_item(
  p_open_item_id uuid,
  p_kind text,
  p_amount numeric,
  p_counterparty_gl_account_id uuid,
  p_reason text,
  p_entry_date date default null::date
) returns fin_open_item_dispositions
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant   uuid := get_my_tenant_id();
  v_item     fin_open_items%rowtype;
  v_gl       gl_accounts%rowtype;
  v_consumed numeric;
  v_available numeric;
  v_lines    jsonb;
  v_je       journal_entries%rowtype;
  v_row      fin_open_item_dispositions%rowtype;
  v_date     date := coalesce(p_entry_date, current_date);
  v_desc     text;
  v_version  integer;
<<<<<<< ours
<<<<<<< ours
=======
  v_claim_status text;
>>>>>>> theirs
=======
  v_claim_status text;
>>>>>>> theirs
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if not is_finance_team_member('finance') then
    raise exception 'INS_DISPOSITION_FINANCE: a disposition needs the finance role' using errcode = '42501';
  end if;

  if p_kind not in ('advance_release', 'advance_forfeit',
                    'claim_write_off', 'claim_recovery_uncollectable') then
    raise exception 'INS_DISPOSITION_KIND: unknown disposition kind %. Use advance_release, advance_forfeit, claim_write_off or claim_recovery_uncollectable.', p_kind;
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_DISPOSITION_AMOUNT: the amount must be greater than zero';
  end if;
  if nullif(btrim(p_reason), '') is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_NOTE_REQUIRED: give the reason for the disposition';
  end if;
  if v_date > current_date + 1 then
    raise exception 'INS_DISPOSITION_DATE: the entry date cannot be in the future';
  end if;

  select * into v_item from fin_open_items
   where id = p_open_item_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: open item';
  end if;

  -- Kind must match what the item is. An advance cannot be written off as a claim,
  -- and a claim cannot be released as an advance: the kind selects the accounting,
  -- so a mismatch would be a wrong posting that looks deliberate.
  if p_kind in ('advance_release', 'advance_forfeit')
     and v_item.control_role is distinct from 'client_advance_payable' then
    raise exception 'INS_DISPOSITION_KIND: % applies to a client advance (2040) item; % is a % item',
      p_kind, v_item.document_no, v_item.control_role;
  end if;
  if p_kind in ('claim_write_off', 'claim_recovery_uncollectable')
     and v_item.control_role not in ('client_claim_payable', 'insurer_claim_receivable') then
    raise exception 'INS_DISPOSITION_KIND: % applies to a claim item; % is a % item',
      p_kind, v_item.document_no, v_item.control_role;
  end if;

  select * into v_gl from gl_accounts
   where id = p_counterparty_gl_account_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_DISPOSITION_ACCOUNT: account % is not a GL account of this company', p_counterparty_gl_account_id;
  end if;
  if not v_gl.is_active then
    raise exception 'INS_DISPOSITION_ACCOUNT: account % is inactive', v_gl.account_code;
  end if;
  -- Posting to a control account without a subledger reference is exactly what B6
  -- forbids, so a disposition may not use one as its counterparty.
  if v_gl.is_control_account then
    raise exception 'INS_DISPOSITION_ACCOUNT: % is a control account; a disposition must name an account that is not a control account', v_gl.account_code;
  end if;
  -- For an advance release double entry forces the answer: the credit must go to
  -- the account the item is measured against, or the control account would not move.
  if p_kind = 'advance_release'
     and v_gl.id is distinct from get_posting_account(v_tenant, 'ar_control') then
    raise exception 'INS_DISPOSITION_ACCOUNT: releasing an advance credits the receivable it was paid against; name the ar_control account, not %', v_gl.account_code;
  end if;

  v_consumed := public.fin_open_item_consumed(v_item.id);
  v_available := v_item.amount - v_consumed;
  if p_amount > v_available then
    raise exception 'INS_DISPOSITION_EXCEEDS: % has % outstanding, % cannot be disposed of',
      v_item.document_no, v_available, p_amount;
  end if;

  v_desc := case p_kind
              when 'advance_release' then 'Client advance released to receivable'
              when 'advance_forfeit' then 'Client advance forfeited'
              when 'claim_write_off' then 'Claim balance written off'
              else 'Claim recovery deemed uncollectable' end
            || ' ' || v_item.document_no;

  -- Double entry. For a payable, the item sits on the credit side of its control
  -- account, so reducing it debits the control; for a receivable, reducing it
  -- credits the control. The counterparty carries the equal and opposite leg.
  if v_item.side = 'payable' then
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', get_posting_account(v_tenant, v_item.control_role),
                         'debit', p_amount, 'currency', v_item.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_gl.id,
                         'credit', p_amount, 'currency', v_item.currency, 'description', v_desc));
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', get_posting_account(v_tenant, v_item.control_role),
                         'credit', p_amount, 'currency', v_item.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_gl.id,
                         'debit', p_amount, 'currency', v_item.currency, 'description', v_desc));
  end if;

  if get_posting_account(v_tenant, v_item.control_role) is null then
    raise exception 'INS_DISPOSITION_ACCOUNT: the posting role % is not mapped to a GL account', v_item.control_role;
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'fin_open_item_disposition', v_item.id, v_date, v_desc, v_lines);

  select platform_accounting_policy_version(v_tenant, v_date) into v_version;

  insert into fin_open_item_dispositions (
    tenant_id, open_item_id, kind, amount, currency, counterparty_gl_account_id,
    journal_entry_id, reason, party_account_id, control_role, side,
    source_type, source_id, accounting_policy_version, created_by
  ) values (
    v_tenant, v_item.id, p_kind, p_amount, v_item.currency, v_gl.id,
    v_je.id, btrim(p_reason), v_item.party_account_id, v_item.control_role, v_item.side,
    v_item.source_type, v_item.source_id, coalesce(v_version, 1), auth.uid()
  )
  returning * into v_row;

<<<<<<< ours
<<<<<<< ours
=======
=======
>>>>>>> theirs
  -- Every disposition against a claim is written to the claim's own audit trail here,
  -- in the one place all four kinds pass through. Writing it in each kind's own caller
  -- instead missed the recovery write-off entirely: a recovery declared uncollectable
  -- moved the ledger and left no trace on the claim it came from.
  if v_item.source_type in ('ins_claim_client', 'ins_claim_insurer') then
    select c.status into v_claim_status
      from public.ins_claims c
     where c.id = v_item.source_id and c.tenant_id = v_tenant;
    insert into public.ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
    values (v_tenant, v_item.source_id, v_claim_status, v_claim_status,
            case p_kind
              when 'claim_write_off' then 'Written off '
              when 'claim_recovery_uncollectable' then 'Recovery written off '
              else 'Disposed ' end
            || p_amount || ' to account ' || v_gl.account_code || ': ' || btrim(p_reason));
  end if;

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. A disposition cannot be quietly undone
-- ---------------------------------------------------------------------
-- The journal is the record. Voiding it would restore the balance without a trace
-- of who decided to, which is worse than making the reversal an explicit posting.
create or replace function public.fin_open_item_dispositions_guard() returns trigger
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'INS_DISPOSITION_IMMUTABLE: dispositions are retained; reverse one with a new posting';
  end if;
  if tg_op = 'UPDATE' then
    raise exception 'INS_DISPOSITION_IMMUTABLE: a disposition cannot be edited';
  end if;
  if not public.ins_via_rpc() then
    raise exception 'INS_RPC_ONLY: dispose of an open item with ins_dispose_open_item()' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_fin_open_item_dispositions_guard on fin_open_item_dispositions;
create trigger trg_fin_open_item_dispositions_guard
  before insert or update or delete on fin_open_item_dispositions
  for each row execute function fin_open_item_dispositions_guard();

-- ---------------------------------------------------------------------
-- 7. The existing guards keep working on the new number
-- ---------------------------------------------------------------------
-- fin_open_item_balances and fin_open_item_consumed now include dispositions, so
-- every guard that reads "outstanding" or "consumed" -- allocations, credit
-- applications, claim payouts, the advance release -- sees the reduced balance
-- without being touched. That is the point of putting the arithmetic in one place.


-- ---------------------------------------------------------------------
-- 8. Claim write-offs, on the same primitive
-- ---------------------------------------------------------------------
-- B8's write-off half was blocked for the same reason the advance release was:
-- reducing a client_claim_payable (2030) with no cash. Now it is a disposition.
--
-- Which account absorbs the write-off is the accountant's decision, so it is a
-- required argument and is checked for being a real, non-control account. The
-- journal is:
--
--     Dr 2030 client claim payable      (the balance owed to the claimant falls)
--     Cr <the named account>            (the loss lands where the policy says)
--
-- Nothing here touches commission accounts, which is the pack's requirement for
-- recoveries: a claim write-off is not a commission adjustment and must never post
-- to 4000, 2020 or 1110. That is enforced below rather than left to the caller.
create or replace function public.ins_write_off_claim(
  p_claim_id uuid,
  p_amount numeric,
<<<<<<< ours
  p_expense_gl_account_id uuid,
<<<<<<< ours
  p_reason text
=======
  p_reason text,
=======
  -- Optional since Appendix B Q1. When omitted the contra-claims-expense account is
  -- resolved from the ins_claim_write_off_expense posting role, which is where the
  -- accountant put the decision. When given it must BE that account: "one account for
  -- both" is only true if a caller cannot point the write-off somewhere else.
  p_expense_gl_account_id uuid default null,
  p_reason text default null,
>>>>>>> theirs
  -- A recognised claim leaves TWO open items from one journal: the insurer receivable
  -- and the claimant payable. Writing off only the payable closes the claim while
  -- leaving the receivable open for ever -- nothing would ever clear it, because the
  -- claim it belongs to is closed. Default false preserves today's behaviour, because
  -- whether the insurer receivable goes with it, or is chased separately, is an
  -- accounting decision and not one this migration should take.
  p_also_write_off_insurer boolean default false
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
) returns fin_open_item_dispositions
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_item   fin_open_items%rowtype;
  v_gl     gl_accounts%rowtype;
  v_row    fin_open_item_dispositions%rowtype;
<<<<<<< ours
<<<<<<< ours
=======
  v_ins_item fin_open_items%rowtype;
>>>>>>> theirs
=======
  v_ins_item fin_open_items%rowtype;
  v_contra  uuid;
>>>>>>> theirs
  v_forbidden uuid;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: writing off a claim balance needs insurance manager authority' using errcode = '42501';
  end if;
  if not is_finance_team_member('finance') then
    raise exception 'INS_WRITE_OFF_FINANCE: a claim write-off needs the finance role' using errcode = '42501';
  end if;

  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  if v_claim.status in ('closed', 'repudiated') then
    raise exception 'INS_CLAIM_STATE: a % claim cannot be written off', v_claim.status;
  end if;

<<<<<<< ours
  select * into v_gl from gl_accounts
   where id = p_expense_gl_account_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_WRITE_OFF_ACCOUNT: account % is not a GL account of this company', p_expense_gl_account_id;
=======
  -- Appendix B Q1/Q4: one contra-claims-expense account for the write-off and the
  -- recovery. Resolved from the posting role when not supplied.
  v_contra := coalesce(p_expense_gl_account_id, public.ins_claim_contra_account(v_tenant));
  if v_contra is null then
    raise exception 'INS_WRITE_OFF_ACCOUNT: no contra-claims-expense account is configured. Map the ins_claim_write_off_expense posting role (Appendix B Q1) before writing off a claim.';
  end if;
  if p_expense_gl_account_id is not null
     and public.ins_claim_contra_account(v_tenant) is not null
     and p_expense_gl_account_id is distinct from public.ins_claim_contra_account(v_tenant) then
    raise exception 'INS_WRITE_OFF_ACCOUNT: a claim write-off posts to the contra-claims-expense account, which is already configured. Appendix B Q1 names one account for write-offs and recoveries; to change it, change the posting role, not this call.';
  end if;

  select * into v_gl from gl_accounts
   where id = v_contra and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_WRITE_OFF_ACCOUNT: account % is not a GL account of this company', v_contra;
>>>>>>> theirs
  end if;
  if v_gl.account_type not in ('expense', 'revenue') then
    raise exception 'INS_WRITE_OFF_ACCOUNT: a write-off is absorbed by an expense (or revenue contra) account; % is %',
      v_gl.account_code, v_gl.account_type;
  end if;

  -- The pack's rule for recoveries: never touch commission accounts.
  foreach v_forbidden in array array[
    get_posting_account(v_tenant, 'commission_income'),
    get_posting_account(v_tenant, 'unearned_commission'),
    get_posting_account(v_tenant, 'commission_receivable')]
  loop
    if v_forbidden is not null and v_forbidden = v_gl.id then
      raise exception 'INS_WRITE_OFF_COMMISSION: a claim write-off may not post to % -- commission accounts are never adjusted by a claim write-off',
        v_gl.account_code;
    end if;
  end loop;

  -- The claim's payable to the claimant (2030). ins_recognise_claim_receivable
  -- creates it with source_type 'ins_claim_client' and source_id = the claim id, so
  -- it is looked up directly rather than guessed from the party.
  select * into v_item from fin_open_items
   where tenant_id = v_tenant
     and source_type = 'ins_claim_client'
     and source_id = v_claim.id
     and control_role = 'client_claim_payable'
   order by created_at limit 1 for update;
  if not found then
    raise exception 'INS_WRITE_OFF_NO_ITEM: claim % has no client claim payable (2030) open item; recognise the receivable before writing anything off', v_claim.claim_no;
  end if;

<<<<<<< ours
<<<<<<< ours
  v_row := public.ins_dispose_open_item(
    v_item.id, 'claim_write_off', p_amount, v_gl.id, p_reason, current_date);

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_claim.id, v_claim.status, v_claim.status,
          'Written off ' || p_amount || ' to account ' || v_gl.account_code || ': ' || btrim(p_reason));
=======
=======
>>>>>>> theirs
  -- ins_dispose_open_item() records the claim event itself, because it is the one path
  -- every claim disposition takes. Writing a second one here would double the trail.
  v_row := public.ins_dispose_open_item(
    v_item.id, 'claim_write_off', p_amount, v_gl.id, p_reason, current_date);

  -- The insurer receivable side of the same claim. Same amount, same account, same
  -- date, so the pair reads as one decision rather than two.
  if p_also_write_off_insurer then
    select * into v_ins_item from fin_open_items
     where tenant_id = v_tenant
       and source_type = 'ins_claim_insurer'
       and source_id = v_claim.id
       and control_role = 'insurer_claim_receivable'
     order by created_at limit 1 for update;
    if found then
      perform public.ins_dispose_open_item(
        v_ins_item.id, 'claim_write_off', p_amount, v_gl.id,
        p_reason || ' (insurer receivable)', current_date);
    end if;
  end if;
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs

  return v_row;
end;
$$;

<<<<<<< ours
<<<<<<< ours
revoke all on function public.ins_write_off_claim(uuid, numeric, uuid, text) from public;
grant execute on function public.ins_write_off_claim(uuid, numeric, uuid, text) to authenticated;
=======
revoke all on function public.ins_write_off_claim(uuid, numeric, uuid, text, boolean) from public;
grant execute on function public.ins_write_off_claim(uuid, numeric, uuid, text, boolean) to authenticated;
>>>>>>> theirs
=======
revoke all on function public.ins_write_off_claim(uuid, numeric, uuid, text, boolean) from public;
grant execute on function public.ins_write_off_claim(uuid, numeric, uuid, text, boolean) to authenticated;
>>>>>>> theirs

revoke all on function public.ins_dispose_open_item(uuid, text, numeric, uuid, text, date) from public;
grant execute on function public.ins_dispose_open_item(uuid, text, numeric, uuid, text, date) to authenticated;

comment on function public.ins_dispose_open_item(uuid, text, numeric, uuid, text, date) is
  'Moves a party balance without cash. Advance release (Dr 2040 / Cr AR) and claim write-off (Dr claim control / Cr the named expense). The counterparty account is the accounting-policy choice and must be named by the caller.';

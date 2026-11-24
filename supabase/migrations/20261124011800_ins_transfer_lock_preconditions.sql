-- =====================================================================
-- Transfer lock: zero-tolerance preconditions
-- Accountant pack v2, B9 (2) and A12
-- =====================================================================
-- The lock itself was restored in 20261124011200 and is approved as a deliberate behaviour
-- change (AE1): concurrent commission transfers serialise on the policies that hold earned
-- commission, before any client-money position is read, so two transfers cannot each see a
-- sufficient free position and together overdraw it.
--
-- This migration closes the two gaps left in that guard. It changes no behaviour for a
-- caller that was already being refused, and it removes no check.
--
-- 1. AN ENTRY ALREADY MOVED BY A POSTED TRANSFER IS REFUSED.
--
--    ins_commission_entries.status has three values and the CHECK constraint ties transfer_id
--    to them: 'earned' means earned_on is set and transfer_id is NULL. When a transfer is
--    VOIDED, ins_void_commission_transfer sets its entries back to status = 'earned' and
--    transfer_id = NULL. So 'earned' does NOT mean "never transferred" -- it also means
--    "transferred, then voided".
--
--    Every selection in this function filters on status = 'earned'. Before this migration an
--    entry that is still sitting on a POSTED transfer could therefore be named again by a new
--    transfer. The money would move twice, and the only thing that could undo it is the void
--    path -- which needs a reason and an independent reviewer, i.e. exactly the situation the
--    double movement should never have created. Whether that state is reachable today depends
--    on the void path being the only writer that resets status, which is true but is a fact
--    about a different function; this migration makes the transfer itself refuse instead.
--
--    It is a precondition on the requested entries only, not on the pool. With
--    p_entry_ids = NULL the function takes every eligible entry, and an entry on a posted
--    transfer cannot be eligible in the first place -- so the check is meaningful exactly
--    where the caller chose the money, which is where a stale selection would come from. It
--    is skipped when no entries were requested, so the pre-existing behaviour of the
--    no-argument path is untouched.
--
-- 2. SELECTION AND LOCKING IN ONE STATEMENT, RE-VERIFIED.
--
--    The previous form aggregated the eligible ids in one statement and locked them in
--    another. That is safe today, but only because the policy-level lock above happens to
--    cover the same rows: two sessions cannot reach the aggregate concurrently for the same
--    policy. The safety is real but it is distributed across three places in the file, and a
--    later edit that moved a block could remove it without any test noticing -- which is
--    exactly how the position test became unreachable once before (see the comment above
--    INS_TRANSFER_TRUST_SHORT, which records that history).
--
--    Folding the lock into the selecting statement makes the function safe on its own terms.
--    The locked set is then re-verified against the requested set: under READ COMMITTED a
--    concurrent commit makes the locking statement re-evaluate its WHERE clause against the
--    updated row version and return FEWER rows, leaving v_total as the total of fewer entries
--    than v_ids named. The count check turns that silent shortfall into a refusal.
--
-- What this does NOT fix, stated rather than left to be found:
--
--   * The guard is still per-tenant serialisation, not per-policy. Two transfers handling
--     disjoint policies in the same company will serialise even though they do not conflict.
--     That is a throughput cost, not a correctness one, and narrowing it is a separate
--     change with its own deadlock analysis.
--   * There is no database-level uniqueness that prevents one entry appearing on two
--     transfers. The refusal above is a guard, and a guard is only as good as its being
--     reached; a constraint would be better and is not expressible while voided entries are
--     reset rather than marked.
-- =====================================================================

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

  -- Serialise concurrent transfers before reading any position.
  --
  -- The shipped ins_transfer_earned_commission is a thin wrapper that took this lock and
  -- then called platform_ins_transfer_before_cancellation_impl. This function replaces both
  -- by inlining the body, so the lock has to be taken here. It was NOT: 20261121150000
  -- re-issued the impl with only the entries-level lock, so between that migration and this
  -- one, two transfers could each read a sufficient client-money position, both pass, and
  -- together overdraw it. Ordering by p.id keeps two concurrent callers from deadlocking on
  -- each other. Restored deliberately, not incidentally -- it is a behaviour change against
  -- the impl as it ships today, and it is the behaviour the original wrapper documented.
  perform p.id from ins_policies p
   where p.tenant_id = v_tenant
     and exists (select 1 from ins_commission_entries e
                  where e.policy_id = p.id and e.status = 'earned'
                    and (p_entry_ids is null or e.id = any (p_entry_ids)))
   order by p.id
     for update;

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

  -- ---------------------------------------------------------------
  -- ZERO-TOLERANCE PRECONDITIONS (20261124011800)
  -- ---------------------------------------------------------------
  -- 1. No entry may already be committed to a posted transfer. An entry's status goes back
  --    to 'earned' when its transfer is VOIDED (ins_void_commission_transfer does that), so
  --    'earned' alone does not mean "never transferred". Without this test an entry could be
  --    named by a second transfer while the first is still posted, and the money would move
  --    twice: the void path is the only thing that can undo it, and it needs a reason and an
  --    independent reviewer. This is a refusal, not a convention.
  if p_entry_ids is not null and exists (
       select 1
         from ins_commission_entries e
         join ins_commission_transfers t on t.id = e.transfer_id
        where e.tenant_id = v_tenant
          and e.id = any (p_entry_ids)
          and t.status = 'posted'
     ) then
    raise exception 'INS_TRANSFER_ALREADY_TRANSFERRED: at least one selected entry was already moved by a posted transfer. Void that transfer first if the money genuinely has to move again.';
  end if;

  -- 2. Deterministic lock order, and selection and locking in ONE statement.
  --
  --    The previous form aggregated the eligible ids in one statement and locked them in
  --    another. That is safe only because the policy-level lock above happens to cover the
  --    same rows -- two sessions cannot reach the aggregate concurrently for the same policy.
  --    Relying on that is asking a reader to reconstruct a deadlock-freedom proof from three
  --    separate places in the file. Folding selection and locking together makes the function
  --    safe on its own terms, so the ordering guarantee cannot be broken by moving a block.
  --
  --    The locked set is re-verified against the requested set below. If a concurrent transfer
  --    committed between the policy lock and here, this statement re-evaluates the WHERE
  --    clause against the updated row version under READ COMMITTED and silently returns FEWER
  --    rows -- and v_total would then be the total of fewer entries than v_ids claimed. The
  --    count check turns that silent shortfall into a refusal.
  with locked as (
    select e.id, e.amount, e.earned_on
      from ins_commission_entries e
     where e.tenant_id = v_tenant
       and e.status = 'earned'
       and not exists (select 1 from ins_policy_cancellations c
                        where c.policy_id = e.policy_id and c.status = 'posted')
       and (p_entry_ids is null or e.id = any (p_entry_ids))
     order by e.id
       for update
  )
  select array_agg(l.id order by l.id), sum(l.amount), max(l.earned_on)
    into v_ids, v_total, v_max_date
    from locked l;

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
  -- (the entries were already locked by the statement above; the bare lock that used to be here
  -- is gone, because a lock taken separately from the selection cannot be defended as covering it)

  if p_transfer_date < v_max_date then
    raise exception 'INS_TRANSFER_DATE: the transfer date cannot be before commission was earned (%)', v_max_date;
  end if;

  -- The old guard's figure, kept because it is a different statement from the position
  -- test and both are worth making: this one says the account HOLDS the money, the
  -- position test says the money is free. Neither implies the other.
  --
  -- This must come AFTER the array_agg above, and did not, briefly. With v_total still
  -- null the comparison `v_trust < v_total` evaluates to NULL, the IF is skipped, and
  -- INS_TRANSFER_TRUST_SHORT becomes unreachable -- a control that reads as present and
  -- can never fire. The shipped order was correct; moving the block "to the top, next to
  -- the other bank checks" is what broke it. Do not move it again.
  select coalesce(sum(l.debit - l.credit), 0) into v_trust
    from journal_entry_lines l
   where l.tenant_id = v_tenant and l.gl_account_id = v_from.gl_account_id
     and l.currency = v_ccy;
  if v_trust < coalesce(v_total, 0) then
    raise exception 'INS_TRANSFER_TRUST_SHORT: client-money account % holds % in the ledger, less than the % to transfer',
      v_from.name, v_trust, v_total;
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

comment on function public.ins_transfer_earned_commission(uuid, uuid, date, uuid[], text) is
  'Moves earned commission from a client-money account to an operating account. Serialises concurrent transfers per company on the policies holding earned commission before reading any position; refuses an entry already sitting on a posted transfer; selects and locks the entries in one statement and re-verifies the locked set. Re-issued by 20261124011800.';

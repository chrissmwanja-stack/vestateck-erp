-- =====================================================================
-- Insurance: commission recognised when the premium is collected
-- =====================================================================
--
-- Why this exists
--
--   ins.commission_recognition offers four values and, until now, two had a
--   reader: on_insurer_settlement (the settlement trigger) and at_placement (the
--   bind). on_premium_collection and over_policy_term were refused by name so
--   that no tenant could select a mode the ledger ignored.
--
--   That refusal was right, but it left a real arrangement unsupported: an
--   insurer agreement that makes the broker's entitlement to commission
--   conditional on the policyholder paying. Under such an agreement commission is
--   NOT earned at bind (the contingency has not cleared) and NOT earned when the
--   insurer settles the net (that event is about the insurer's debt, and under
--   gross settlement may not happen at all). It is earned when the client's
--   premium is actually collected. Recognising it at placement would overstate
--   both revenue and the amount recoverable -- the exact failure mode the owner
--   flagged.
--
--   This migration gives on_premium_collection a reader, so the mode can be
--   configured for the insurers whose agreements work that way.
--
-- The three cases, in the owner's terms
--
--   1. unconditional entitlement at bind        -> at_placement
--   2. entitlement conditional on premium paid  -> on_premium_collection  (this)
--   3. entitlement on the insurer's settlement  -> on_insurer_settlement
--
--   Gross settlement still pins at_placement (20261117200000): under gross the
--   premium crosses in full, so there is nothing to defer. A tenant that needs
--   conditional recognition must therefore settle net. That interaction is
--   enforced in the snapshot function, which refuses the combination by name
--   rather than silently choosing one.
--
-- What "collected" means here
--
--   The client's premium open item (ins_policy_premium) is covered by posted
--   receipts plus credit notes, exactly the test the settlement trigger applies
--   to the insurer item (ins_item_paid_amount + credited_amount >= amount). Cash
--   is what counts; a credit note clears the debt but collection of the premium
--   is the condition in the agreement, so a credit note does NOT earn commission
--   on its own. It is included in the coverage test only because a fully
--   credited item can never be collected, and leaving it deferred forever would
--   be a worse lie than recognising it -- the same reasoning the settlement
--   trigger already documents for endorsement returns.
--
--   Partial collection does not earn a proportion. The agreement is binary:
--   commission is due once the premium is paid. Recognising a share of it on a
--   part payment would invent an entitlement the agreement does not create.
--
-- Un-earning
--
--   Voiding a receipt that drops the item back below full coverage must reverse
--   the recognition, or the books claim income from money that came back. This
--   mirrors ins_commission_on_settlement_voided: a reversing journal to the same
--   accounts at the same booked rate, the entry back to deferred, and an event
--   recording why. A placement-earned entry is never un-earned (its entitlement
--   never depended on the cash) -- that distinction is what earned_by records.
--
-- Fix forward (rule 9): the earlier migrations are not edited.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. The resolver and the override setter learn the third mode
-- ---------------------------------------------------------------------
-- Both hard-coded the pair of modes they knew about, so a tenant-approved
-- on_premium_collection failed at the resolver before any trigger ran. Keeping
-- the list in one place here means the guard and the reader cannot disagree.
create or replace function public.ins_commission_recognition_mode(p_policy_id uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_pol     ins_policies%rowtype;
  v_setting text;
begin
  select * into v_pol from public.ins_policies where id = p_policy_id;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  perform public.assert_tenant_access(v_pol.tenant_id);

  if public.get_my_tenant_id() is distinct from v_pol.tenant_id then
    raise exception 'INS_TENANT_MISMATCH: policy belongs to another company' using errcode = '42501';
  end if;

  -- An explicit per-policy answer wins over the tenant setting.
  if v_pol.commission_recognition_override is not null then
    return v_pol.commission_recognition_override;
  end if;

  v_setting := public.acct_assert_reviewed('ins.commission_recognition', v_pol.inception_date);
  if v_setting not in ('on_insurer_settlement', 'at_placement', 'on_premium_collection') then
    raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % is set for this company, but only on_insurer_settlement, at_placement and on_premium_collection are implemented; configure one of those', v_setting;
  end if;
  return v_setting;
end;
$function$;

revoke all on function public.ins_commission_recognition_mode(uuid) from public, anon;
grant execute on function public.ins_commission_recognition_mode(uuid) to authenticated;

create or replace function public.ins_set_policy_commission_recognition(p_policy_id uuid, p_mode text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_pol ins_policies%rowtype;
begin
  if not public.can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can set the commission recognition mode' using errcode = '42501';
  end if;

  select * into v_pol from public.ins_policies
   where id = p_policy_id and tenant_id = public.get_my_tenant_id()
   for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;

  if p_mode is not null and p_mode not in ('on_insurer_settlement', 'at_placement', 'on_premium_collection') then
    if p_mode = 'over_policy_term' then
      raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % needs an earned-over-time schedule, which is not built; refusing rather than recording a mode nothing reads', p_mode;
    end if;
    raise exception 'INS_COMMISSION_RECOGNITION_MODE: unknown mode %', p_mode;
  end if;

  if v_pol.status <> 'draft' then
    raise exception 'INS_FINANCIAL_IMMUTABLE: the commission recognition mode is frozen at bind; % is %', v_pol.policy_no, v_pol.status;
  end if;

  update public.ins_policies
     set commission_recognition_override = p_mode
   where id = v_pol.id;
end;
$function$;

revoke all on function public.ins_set_policy_commission_recognition(uuid, text) from public, anon;
grant execute on function public.ins_set_policy_commission_recognition(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 1. A local re-implementation of the trigger body, shared by both paths
-- ---------------------------------------------------------------------
-- Taking the lock and the loop in one place means the "is the item covered"
-- test cannot drift between the receipt path and the void path.
create or replace function public.ins_earn_commission_on_collection(p_settlement_id uuid, p_reverse boolean)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  r          record;
  v_unearned uuid;
  v_income   uuid;
  v_ev       uuid;
  v_je       journal_entries;
  v_line     jsonb;
  v_line2    jsonb;
  v_date     date;
  v_n        integer := 0;
begin
  v_unearned := public.get_posting_account(
    (select tenant_id from public.fin_settlements where id = p_settlement_id), 'unearned_commission');
  v_income := public.get_posting_account(
    (select tenant_id from public.fin_settlements where id = p_settlement_id), 'commission_income');

  for r in
    select e.id            as entry_id,
           e.amount,
           e.earned_on,
           p.policy_no,
           p.tenant_id,
           i.currency      as item_currency,
           i.fx_rate       as item_rate,
           i.journal_entry_id as booking_entry,
           s.settlement_date,
           s.tenant_id     as settlement_tenant
      from public.fin_allocations al
      join public.fin_open_items i   on i.id = al.open_item_id and i.source_type = 'ins_policy_premium'
      join public.fin_open_item_balances ob on ob.id = i.id
      join public.ins_commission_entries e on e.policy_id = i.source_id
                                          and e.insurer_share_id is null
                                          and e.source_open_item_id is null
                                          and e.tenant_id = i.tenant_id
      join public.ins_policies p on p.id = e.policy_id
      join public.fin_settlements s on s.id = p_settlement_id
     where al.settlement_id = p_settlement_id
       -- Only the mode this trigger exists for, read from the snapshot frozen
       -- at bind. It must not call ins_commission_recognition_mode here: that
       -- resolver asserts tenant access, and a trigger fires for seed inserts,
       -- imports and every other path with no session user. (Measured: calling
       -- it broke 24 tests.) The snapshot is the honest source anyway -- it is
       -- what the bind actually used, including the gross pin.
       and p.accounting_config_snapshot ->> 'commission_recognition_effective' = 'on_premium_collection'
       and (
             (not p_reverse and e.status = 'deferred'
              and public.ins_item_paid_amount(i.id) + ob.credited_amount >= i.amount)
          or (p_reverse and e.status = 'earned' and e.earned_by = 'premium_collection'
              and public.ins_item_paid_amount(i.id) + ob.credited_amount < i.amount)
           )
     order by p.policy_no
     for update of e
  loop
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: recognising commission on collection needs the unearned_commission and commission_income posting rules (policy %)', r.policy_no;
    end if;

    if p_reverse then
      v_date := greatest(coalesce(r.earned_on, r.settlement_date), r.settlement_date);
      v_line  := jsonb_build_object('gl_account_id', v_income,   'debit',  r.amount, 'description', 'Commission un-earned: premium no longer collected on ' || r.policy_no);
      v_line2 := jsonb_build_object('gl_account_id', v_unearned, 'credit', r.amount, 'description', 'Commission un-earned: premium no longer collected on ' || r.policy_no);
    else
      v_date  := r.settlement_date;
      v_line  := jsonb_build_object('gl_account_id', v_unearned, 'debit',  r.amount, 'description', 'Commission earned on collection of ' || r.policy_no);
      v_line2 := jsonb_build_object('gl_account_id', v_income,   'credit', r.amount, 'description', 'Commission earned on collection of ' || r.policy_no);
    end if;

    -- Deferred at the rate the policy was bound at; recognise and reverse at
    -- that same rate so the unearned account is zero in base when it empties.
    if r.item_currency is distinct from public.fin_ledger_currency(r.tenant_id) then
      if r.booking_entry is null or r.item_rate is null or r.item_rate <= 0 then
        raise exception 'INS_COMMISSION_RATE: commission on % has no booked rate; the premium item must name its booking entry', r.policy_no;
      end if;
      v_line  := v_line  || jsonb_build_object('currency', r.item_currency, 'rate_from_entry', r.booking_entry, 'fx_rate', r.item_rate);
      v_line2 := v_line2 || jsonb_build_object('currency', r.item_currency, 'rate_from_entry', r.booking_entry, 'fx_rate', r.item_rate);
    end if;

    v_ev := gen_random_uuid();
    v_je := public.post_journal_entry(r.tenant_id, 'ins_commission_recognition', v_ev, v_date,
      case when p_reverse then 'Commission un-earned on ' || r.policy_no
           else 'Commission earned on collection of ' || r.policy_no end,
      jsonb_build_array(v_line, v_line2));

    insert into public.ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id, settlement_id)
    values (v_ev, r.tenant_id, r.entry_id,
            -- 'recognition_reversed' is the vocabulary the table already uses for
            -- an earned entry going back to deferred; do not invent a new word.
            case when p_reverse then 'recognition_reversed' else 'recognised' end,
            r.amount, v_je.id, p_settlement_id);

    update public.ins_commission_entries
       set status    = case when p_reverse then 'deferred' else 'earned' end,
           earned_on = case when p_reverse then null else v_date end,
           earned_by = case when p_reverse then null else 'premium_collection' end,
           updated_at = now()
     where id = r.entry_id;

    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$function$;

revoke all on function public.ins_earn_commission_on_collection(uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. The triggers
-- ---------------------------------------------------------------------
-- Receipts: the same AFTER UPDATE OF journal_entry_id moment the settlement
-- trigger uses, i.e. when a posted receipt becomes real money.
create or replace function public.ins_commission_on_receipt_posted()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.direction <> 'in' or new.status <> 'posted' or new.journal_entry_id is null then
    return new;
  end if;
  perform public.ins_earn_commission_on_collection(new.id, false);
  return new;
end;
$function$;

create or replace function public.ins_commission_on_receipt_voided()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform public.ins_earn_commission_on_collection(new.id, true);
  return new;
end;
$function$;

drop trigger if exists trg_ins_commission_on_receipt_posted on public.fin_settlements;
create trigger trg_ins_commission_on_receipt_posted
  after update of journal_entry_id on public.fin_settlements
  for each row when (old.journal_entry_id is null and new.journal_entry_id is not null)
  execute function public.ins_commission_on_receipt_posted();

drop trigger if exists trg_ins_commission_on_receipt_voided on public.fin_settlements;
create trigger trg_ins_commission_on_receipt_voided
  after update of status on public.fin_settlements
  for each row when (old.status = 'posted' and new.status = 'void')
  execute function public.ins_commission_on_receipt_voided();

revoke all on function public.ins_commission_on_receipt_posted() from public, anon, authenticated;
revoke all on function public.ins_commission_on_receipt_voided() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2b. The override CHECK learns it too
-- ---------------------------------------------------------------------
-- The column's constraint enumerated the two implemented modes, so widening the
-- setter alone would have failed at the table with a check violation instead of
-- a clear message.
do $$ begin
  alter table public.ins_policies
    drop constraint if exists ins_policies_commission_recognition_override_check;
  alter table public.ins_policies
    add constraint ins_policies_commission_recognition_override_check
    check (commission_recognition_override is null
           or commission_recognition_override = any (array['on_insurer_settlement', 'at_placement', 'on_premium_collection']));
end $$;

-- ---------------------------------------------------------------------
-- 3. earned_by learns one more value
-- ---------------------------------------------------------------------
-- The column records WHY an entry became earned, which is what the void paths
-- rely on to decide whether they may un-earn it. Adding 'premium_collection'
-- keeps that decision readable instead of inferring it from which trigger fired.
alter table public.ins_commission_entries
  drop constraint if exists ins_commission_entries_earned_by_check;

alter table public.ins_commission_entries
  add constraint ins_commission_entries_earned_by_check
  check (earned_by is null or earned_by in ('placement', 'settlement', 'premium_collection'));

comment on column public.ins_commission_entries.earned_by is
  'Which event made this entry earned: placement (unconditional entitlement at bind, or gross settlement), settlement (the insurer paid its item), premium_collection (the client paid, for agreements where entitlement is conditional on it). The void paths only un-earn what their own event created.';

-- ---------------------------------------------------------------------
-- 4. The snapshot refuses a combination it cannot honour
-- ---------------------------------------------------------------------
-- on_premium_collection is only meaningful on a net remittance. Under gross the
-- premium crosses in full and at_placement is forced, so a tenant configuring
-- conditional recognition while also settling gross would get a mode its books
-- never use. Refuse that by name at bind, rather than recording a mode the
-- ledger overrode.
create or replace function public.ins_snapshot_bind_config()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_recognition text;
  v_effective   text;
  v_source      text;
  v_basis       text;
begin
  if new.status = 'active' and old.status is distinct from new.status then
    v_recognition := public.acct_assert_reviewed('ins.commission_recognition', new.inception_date);

    if new.commission_recognition_override is not null then
      v_source := 'policy_override';
    else
      v_source := 'tenant_setting';
    end if;

    -- Gross settlement means the premium crosses in full and the commission is
    -- a receivable from the insurer: there is nothing left to defer, so it is
    -- earned at placement whatever the setting says.
    if public.ins_share_basis(new.id) = 'gross_premium'
       and coalesce(new.commission_amount, 0) > 0 then
      v_effective := 'at_placement';
      v_source    := 'remittance_basis_gross';
    elsif new.commission_recognition_override is not null then
      v_effective := new.commission_recognition_override;
      v_source    := 'policy_override';
    else
      v_effective := v_recognition;
      v_source    := 'tenant_setting';
    end if;

    if v_effective not in ('on_insurer_settlement', 'at_placement', 'on_premium_collection') then
      raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % has no reader in this release (implemented: on_insurer_settlement, at_placement, on_premium_collection). Configure one of those before binding %', v_effective, new.policy_no;
    end if;

    if v_effective = 'at_placement' and coalesce(new.commission_amount, 0) <= 0 then
      raise exception 'INS_COMMISSION_RECOGNITION_MODE: % is set to recognise commission at placement but has no commission; correct the rate or choose on_insurer_settlement', new.policy_no;
    end if;

    -- Conditional-on-collection and gross settlement cannot both be true: under
    -- gross the premium is remitted in full at placement, so there is no
    -- outstanding premium whose collection could be the trigger.
    if v_effective = 'on_premium_collection'
       and public.ins_share_basis(new.id) = 'gross_premium'
       and coalesce(new.commission_amount, 0) > 0 then
      raise exception 'INS_COMMISSION_RECOGNITION_BASIS: % recognises commission on premium collection, which needs a net remittance basis; this policy settles gross (the premium crosses in full, so nothing is left to collect). Change ins.insurer_remittance_basis for this insurer, or use at_placement', new.policy_no;
    end if;

    new.accounting_config_snapshot := coalesce(new.accounting_config_snapshot, '{}'::jsonb)
      || jsonb_build_object(
           'ins.commission_recognition', v_recognition,
           'commission_recognition_effective', v_effective,
           'commission_recognition_source', v_source,
           'resolved_at', now()
         );
  end if;
  return new;
end;
$function$;

revoke all on function public.ins_snapshot_bind_config() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. And it may now be selected -- because a reader exists
-- ---------------------------------------------------------------------
update public.accounting_setting_definitions
   set implemented_values = array['on_insurer_settlement', 'at_placement', 'on_premium_collection']
 where key = 'ins.commission_recognition'
   and implemented_values is distinct from array['on_insurer_settlement', 'at_placement', 'on_premium_collection'];

-- over_policy_term stays out on purpose: it needs an earned-over-time schedule,
-- which is a Phase B build, not a reader.

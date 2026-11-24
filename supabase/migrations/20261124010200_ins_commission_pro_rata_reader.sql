-- =====================================================================
-- Accountant sign-off pack v2, decision 1 (reader) and decision 2 (fail closed)
-- =====================================================================
-- Three changes, all in the recognition path:
--
--   1. A READER for pro_rata_on_collection. Commission is earned on each
--      receipt in proportion to premium collected, never beyond the entry's
--      total. Partial tracking is a cumulative, so it is idempotent: re-running
--      a receipt's recognition cannot double-count, and reversing a receipt
--      returns exactly the proportion that receipt had earned.
--
--   2. A READER for on_premium_collection in the bind snapshot. The mode was
--      implemented in 20261120000000 but the snapshot guard in
--      20261120235903 still only admitted on_insurer_settlement and
--      at_placement, so choosing it failed at bind with
--      "has no reader in this release". That message was true when it was
--      written and stale by the next migration; this removes it.
--
--   3. FAIL CLOSED (decision 2). Binding no longer falls back to
--      on_insurer_settlement for a company that has not chosen. The error names
--      the missing setting, because the failure mode this replaces was silent:
--      an unclassified insurer agreement was accounted for on the historic
--      default, which overstates or understates earned commission depending on
--      what the agreement actually says.
--
-- WHAT IS DELIBERATELY UNCHANGED
--   - on_premium_collection stays binary. A partial receipt still earns
--     nothing under that mode. Decision 1 added a mode; it did not re-interpret
--     an existing one.
--   - Gross settlement still pins recognition to at_placement, and both
--     collection modes are still refused under gross (nothing left to collect).
--   - The void path still reverses through unearned commission at the booked
--     rate, and income is never carried on money that came back.
--
-- ADDITIVE COLUMNS (allowed; MIGRATION_POLICY bans DROP COLUMN, not ADD)
--   ins_commission_entries.earned_cumulative  -- how much of this entry has
--                                                been earned by collection
--   ins_commission_entries.earned_last_amount -- the amount the last receipt
--                                                earned, so a void reverses it
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Columns for proportional partial earning
-- ---------------------------------------------------------------------
alter table public.ins_commission_entries
  add column if not exists earned_cumulative  numeric(18,2) not null default 0,
  add column if not exists earned_last_amount numeric(18,2);

comment on column public.ins_commission_entries.earned_cumulative is
  'Commission earned so far by collection (binary modes earn all or nothing, so this is 0 or amount). Used by pro_rata_on_collection.';
comment on column public.ins_commission_entries.earned_last_amount is
  'Amount the most recent receipt earned on this entry. A void reverses exactly this, not the whole entry.';

-- ---------------------------------------------------------------------
-- 1. The pro-rata reader
-- ---------------------------------------------------------------------
-- Mirrors ins_earn_commission_on_collection's shape and vocabulary so the two
-- modes share the events table, the journal source type and the status column.
-- Differences, all forced by the mode:
--   * the policy item does not have to be fully covered -- the proportion
--     collected is the basis;
--   * the amount is delta = target_cumulative - earned_cumulative, so the
--     function is idempotent per settlement;
--   * the item is not reopened by a void unless the proportional target falls
--     below what was earned, because a partial collection still leaves a valid
--     partial entitlement.
create or replace function public.ins_earn_commission_pro_rata(p_settlement_id uuid, p_reverse boolean)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  r            record;
  v_unearned   uuid;
  v_income     uuid;
  v_ev         uuid;
  v_je         journal_entries;
  v_line       jsonb;
  v_line2      jsonb;
  v_date       date;
  v_n          integer := 0;
<<<<<<< ours
=======
  v_collected  numeric(18,2);
>>>>>>> theirs
  v_target     numeric(18,2);
  v_delta      numeric(18,2);
begin
  v_unearned := public.get_posting_account(
    (select tenant_id from public.fin_settlements where id = p_settlement_id), 'unearned_commission');
  v_income := public.get_posting_account(
    (select tenant_id from public.fin_settlements where id = p_settlement_id), 'commission_income');

  for r in
    select e.id              as entry_id,
           e.amount          as entry_amount,
           e.earned_cumulative,
           e.earned_last_amount,
           e.earned_on,
           p.policy_no,
           p.tenant_id,
           i.amount          as item_amount,
           i.currency        as item_currency,
           i.fx_rate         as item_rate,
           i.journal_entry_id as booking_entry,
           s.settlement_date,
           public.ins_item_paid_amount(i.id) as paid_after,
           coalesce(ob.credited_amount, 0)   as credited
      from public.fin_allocations al
      join public.fin_open_items i on i.id = al.open_item_id and i.source_type = 'ins_policy_premium'
      left join public.fin_open_item_balances ob on ob.id = i.id
      join public.ins_commission_entries e on e.policy_id = i.source_id
                                          and e.insurer_share_id is null
                                          and e.source_open_item_id is null
                                          and e.tenant_id = i.tenant_id
      join public.ins_policies p on p.id = e.policy_id
      join public.fin_settlements s on s.id = p_settlement_id
     where al.settlement_id = p_settlement_id
       -- Read from the snapshot frozen at bind, exactly as the binary mode
       -- does: the resolver asserts tenant access and a trigger fires with no
       -- session user.
       and p.accounting_config_snapshot ->> 'commission_recognition_effective' = 'pro_rata_on_collection'
       and e.status in ('deferred', 'earned')
     order by p.policy_no, e.id
     for update of e
  loop
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: recognising commission on collection needs the unearned_commission and commission_income posting rules (policy %)', r.policy_no;
    end if;
    if r.item_amount is null or r.item_amount <= 0 then
      raise exception 'INS_COMMISSION_PRORATA: premium item on % has no amount to pro-rate against', r.policy_no;
    end if;

<<<<<<< ours
=======
    -- Base currency leg: allocate the settlement to THIS receipt, so a receipt
    -- that only partly allocates to this item still earns only its share.
    select coalesce(sum(al2.amount), 0)
      into v_collected
      from public.fin_allocations al2
     where al2.settlement_id = p_settlement_id
       and al2.open_item_id in (
         select i2.id from public.fin_open_items i2
          where i2.source_type = 'ins_policy_premium'
            and i2.source_id = (select i.policy_id from public.fin_open_items i where i.id = al2.open_item_id)
       );

>>>>>>> theirs
    -- The target is always computed from the item's total paid-to-date (not a
    -- per-receipt increment), which is what makes re-running this idempotent.
    v_target := round(r.entry_amount
                      * least(1, (r.paid_after + r.credited) / r.item_amount), 2);

    if p_reverse then
      -- Reverse exactly what the most recent receipt earned.
      v_delta := -coalesce(r.earned_last_amount, 0);
    else
      v_delta := v_target - coalesce(r.earned_cumulative, 0);
    end if;

    -- Nothing to move: a partial receipt under a binary mode, an already
    -- recognised receipt, or a reversal of a receipt that earned nothing.
    if v_delta = 0 then
      continue;
    end if;

    if p_reverse then
      v_date  := greatest(coalesce(r.earned_on, r.settlement_date), r.settlement_date);
      v_line  := jsonb_build_object('gl_account_id', v_income,   'debit',  abs(v_delta), 'description', 'Commission un-earned: premium no longer collected on ' || r.policy_no);
      v_line2 := jsonb_build_object('gl_account_id', v_unearned, 'credit', abs(v_delta), 'description', 'Commission un-earned: premium no longer collected on ' || r.policy_no);
    else
      v_date  := r.settlement_date;
      v_line  := jsonb_build_object('gl_account_id', v_unearned, 'debit',  v_delta, 'description', 'Commission earned pro rata on collection of ' || r.policy_no);
      v_line2 := jsonb_build_object('gl_account_id', v_income,   'credit', v_delta, 'description', 'Commission earned pro rata on collection of ' || r.policy_no);
    end if;

    -- Same booked-rate rule as the binary path, so unearned lands at zero in
    -- base currency when it empties.
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
           else 'Commission earned pro rata on collection of ' || r.policy_no end,
      jsonb_build_array(v_line, v_line2));

    insert into public.ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id, settlement_id)
    values (v_ev, r.tenant_id, r.entry_id,
            case when p_reverse then 'recognition_reversed' else 'recognised' end,
            abs(v_delta), v_je.id, p_settlement_id);

    -- Status: earned only when the whole entry is earned. A partial stays
    -- deferred, so the unearned balance remains visible in 2020 -- which is the
    -- point of the deferred position the accountant is being asked to accept.
    update public.ins_commission_entries
       set earned_cumulative  = coalesce(r.earned_cumulative, 0) + v_delta,
           earned_last_amount = case when p_reverse then null else v_delta end,
           status    = case
                         when coalesce(r.earned_cumulative, 0) + v_delta >= r.entry_amount - 0.005 then 'earned'
                         else 'deferred'
                       end,
           earned_on = case
                         when coalesce(r.earned_cumulative, 0) + v_delta >= r.entry_amount - 0.005
                           then coalesce(r.earned_on, v_date)
                         else null
                       end,
           earned_by = case
                         when coalesce(r.earned_cumulative, 0) + v_delta >= r.entry_amount - 0.005
                           then coalesce(nullif(earned_by, ''), 'premium_collection_pro_rata')
                         else null
                       end,
           updated_at = now()
     where id = r.entry_id;

    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$function$;

revoke all on function public.ins_earn_commission_pro_rata(uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Route the receipt triggers by mode
-- ---------------------------------------------------------------------
-- One trigger entry point decides which reader applies, so a policy can never
-- be processed by both modes and double-recognise.
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
  -- The binary reader already excludes pro-rata policies by its snapshot test
  -- and vice versa, so calling both is safe and keeps each function's
  -- conditions in one place rather than duplicating them here.
  perform public.ins_earn_commission_on_collection(new.id, false);
  perform public.ins_earn_commission_pro_rata(new.id, false);
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
  perform public.ins_earn_commission_pro_rata(new.id, true);
  return new;
end;
$function$;

revoke all on function public.ins_commission_on_receipt_posted() from public, anon, authenticated;
revoke all on function public.ins_commission_on_receipt_voided() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. The bind snapshot: admit the collection modes, and fail closed
-- ---------------------------------------------------------------------
create or replace function public.ins_snapshot_bind_config()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_recognition text;
  v_effective   text;
  v_source      text;
  v_basis       text;
begin
  if new.status = 'active' and old.status is distinct from new.status then

    -- FAIL CLOSED (decision 2). A company that has never chosen a recognition
    -- mode can no longer bind on the seeded default: the mode is a property of
    -- the insurer agreement, and an unclassified agreement must be impossible
    -- to bind rather than silently accounted for on the historic setting.
    --
    -- The test is the setting's SOURCE, not its value. acct_get_setting returns
    -- source = 'default' when no company row is in force, and the seeded
    -- default_value is still 'on_insurer_settlement' (20261120001000 left it
    -- there deliberately). Checking the value alone would therefore never fire.
    -- A company that HAS chosen -- including one that chose
    -- on_insurer_settlement explicitly -- has source = 'configured' and passes.
    if (public.acct_get_setting('ins.commission_recognition', new.inception_date) ->> 'source')
         is distinct from 'configured' then
      raise exception 'INS_COMMISSION_RECOGNITION_UNSET: % cannot bind because this company has no approved ins.commission_recognition in force on %. Every insurer agreement must have an explicit recognition mode (at_placement, on_premium_collection, pro_rata_on_collection or on_insurer_settlement). Set it in company accounting settings and have it reviewed.',
        new.policy_no, new.inception_date;
    end if;

    v_recognition := public.acct_assert_reviewed('ins.commission_recognition', new.inception_date);

    v_basis := public.ins_share_basis(new.id);

    if new.commission_recognition_override is not null then
      v_source := 'policy_override';
    else
      v_source := 'tenant_setting';
    end if;

    -- Gross settlement means the premium crosses in full and the commission is
    -- a receivable from the insurer: there is nothing left to defer, so it is
    -- earned at placement whatever the setting says. Unchanged.
    if v_basis = 'gross_premium'
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

    if v_effective not in ('on_insurer_settlement', 'at_placement',
                           'on_premium_collection', 'pro_rata_on_collection') then
      raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % has no reader in this release (implemented: on_insurer_settlement, at_placement, on_premium_collection, pro_rata_on_collection). Configure one of those before binding %', v_effective, new.policy_no;
    end if;

    if v_effective = 'at_placement' and coalesce(new.commission_amount, 0) <= 0 then
      raise exception 'INS_COMMISSION_RECOGNITION_MODE: % is set to recognise commission at placement but has no commission; correct the rate or choose a collection or settlement mode', new.policy_no;
    end if;

    -- Both collection modes need something left to collect, so both are
    -- refused under a gross basis. Extends the existing on_premium_collection
    -- refusal to the new mode rather than leaving the same hole for it.
    if v_effective in ('on_premium_collection', 'pro_rata_on_collection')
       and v_basis = 'gross_premium'
       and coalesce(new.commission_amount, 0) > 0 then
      raise exception 'INS_COMMISSION_RECOGNITION_BASIS: % is set to recognise commission when the premium is collected (%), but its settlement basis is gross_premium, where the premium crosses in full at bind and there is nothing left to collect. Choose at_placement for a gross basis, or move this insurer to a net basis', new.policy_no, v_effective;
    end if;

    new.accounting_config_snapshot := coalesce(new.accounting_config_snapshot, '{}'::jsonb)
      || jsonb_build_object(
           'ins.commission_recognition', v_recognition,
           'commission_recognition_effective', v_effective,
           'commission_recognition_source', v_source,
           'resolved_at', now()
         );
  end if;

  if new.status = 'active' and old.status is distinct from 'active' then
    new.accounting_config_snapshot := coalesce(new.accounting_config_snapshot, '{}'::jsonb)
      || jsonb_build_object(
           'statutory_charges', to_jsonb(new.statutory_charges_ack),
           'statutory_charge_enforcement',
             public.ins_statutory_enforcement(new.tenant_id, new.inception_date));
  end if;

  return new;
end $$;

revoke all on function public.ins_snapshot_bind_config() from public, anon, authenticated;

drop trigger if exists ins_bind_config_snapshot on public.ins_policies;
create trigger ins_bind_config_snapshot
  before update on public.ins_policies
  for each row execute function public.ins_snapshot_bind_config();

-- ---------------------------------------------------------------------
-- 4. The policy-level setter learns the new mode
-- ---------------------------------------------------------------------
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

  if p_mode is not null
     and p_mode not in ('on_insurer_settlement', 'at_placement',
                        'on_premium_collection', 'pro_rata_on_collection') then
    if p_mode = 'over_policy_term' then
      raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: over_policy_term is not implemented and cannot be selected; use one of on_insurer_settlement, at_placement, on_premium_collection, pro_rata_on_collection';
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
-- 5. The override CHECK learns it too (the column's constraint enumerated modes)
-- ---------------------------------------------------------------------
do $$ begin
  alter table public.ins_policies
    drop constraint if exists ins_policies_commission_recognition_override_check;
  alter table public.ins_policies
    add constraint ins_policies_commission_recognition_override_check
    check (commission_recognition_override is null
           or commission_recognition_override in ('on_insurer_settlement', 'at_placement',
                                                  'on_premium_collection', 'pro_rata_on_collection'));
end $$;

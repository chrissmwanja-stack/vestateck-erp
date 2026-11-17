-- =====================================================================
-- Insurance: commission recognition reads the policy's recorded basis
-- =====================================================================
--
-- What this closes
--
--   ins.commission_recognition has always been snapshotted onto the policy at
--   bind (ins_snapshot_bind_config writes it into accounting_config_snapshot),
--   and nothing ever read that snapshot. Recognition was hard-wired: deferred
--   at bind, earned when the insurer was paid. So a tenant could configure
--   "on placement" and the ledger would ignore it, which is the same broken
--   promise the remittance basis had.
--
-- Scope, as instructed: the TENANT setting is the default, and an individual
-- policy may override it. The override lives on the policy, not on the
-- company setting table, for two reasons:
--
--   1. company_accounting_settings is a tenant-wide policy record with
--      approval, compliance review and effective dating. Duplicating that
--      machinery per policy would mean a second approval workflow to reason
--      about, and a tenant-wide report that has to add "unless a policy says
--      otherwise" to every line.
--   2. The policy already carries a snapshot of the settings in force at
--      bind. An override is the same idea with a person's name on it, so it
--      belongs next to it.
--
-- What is implemented, and what is refused
--
--   on_insurer_settlement  earned when the insurer is paid. DEFAULTS HERE.
--   at_placement           earned when the policy is bound.
--
--   on_premium_collection  refused by name (INS_COMMISSION_RECOGNITION_-
--   over_policy_term       UNIMPLEMENTED). Neither has a reader, and shipping
--                          a selectable value with no reader is exactly the
--                          bug this migration exists to fix. They stay out of
--                          implemented_values, so the settings screen rejects
--                          them before they ever reach a ledger.
--
-- Net vs gross: under the gross remittance basis there is nothing to defer
-- (the premium crosses in full and the commission is a receivable from the
-- insurer), so gross pins at_placement regardless of the setting. That
-- precedence is not configurable and the bind says so in the snapshot.

-- ---------------------------------------------------------------------
-- 1. A policy may record its own recognition mode
-- ---------------------------------------------------------------------
alter table public.ins_policies
  add column if not exists commission_recognition_override text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'ins_policies_commission_recognition_override_check'
       and conrelid = 'public.ins_policies'::regclass
  ) then
    alter table public.ins_policies
      add constraint ins_policies_commission_recognition_override_check
      check (commission_recognition_override is null
             or commission_recognition_override = any (array['on_insurer_settlement', 'at_placement']));
  end if;
end $$;

comment on column public.ins_policies.commission_recognition_override is
  'Per-policy override of ins.commission_recognition. Null = use the tenant setting. Read at bind and frozen into accounting_config_snapshot.';

-- ---------------------------------------------------------------------
-- 2. Resolve the mode: override, then tenant setting, then the default
-- ---------------------------------------------------------------------
-- Mirrors ins_share_basis: an explicit per-policy answer wins, otherwise the
-- tenant's approved setting at the policy's inception date, otherwise the
-- definition default.
create or replace function public.ins_commission_recognition_mode(p_policy_id uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_pol        ins_policies%rowtype;
  v_override   text;
  v_setting    text;
begin
  select * into v_pol from public.ins_policies where id = p_policy_id;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  perform public.assert_tenant_access(v_pol.tenant_id);

  v_override := v_pol.commission_recognition_override;
  if v_override is not null then
    return v_override;
  end if;

  -- acct_get_setting scopes to the caller's company, so assert it is this
  -- policy's company before trusting the answer.
  if public.get_my_tenant_id() is distinct from v_pol.tenant_id then
    raise exception 'INS_TENANT_MISMATCH: policy belongs to another company' using errcode = '42501';
  end if;

  v_setting := public.acct_assert_reviewed('ins.commission_recognition', v_pol.inception_date);
  if v_setting not in ('on_insurer_settlement', 'at_placement') then
    raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % is set for this company, but only on_insurer_settlement and at_placement are implemented; configure one of those', v_setting;
  end if;
  return v_setting;
end;
$function$;

revoke all on function public.ins_commission_recognition_mode(uuid) from public, anon;
grant execute on function public.ins_commission_recognition_mode(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Set or clear a policy's override
-- ---------------------------------------------------------------------
-- Draft only: the mode is frozen at bind, and changing it on a live policy
-- would silently re-label commissions that are already posted.
create or replace function public.ins_set_policy_commission_recognition(
  p_policy_id uuid,
  p_mode      text)
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

  if p_mode is not null and p_mode not in ('on_insurer_settlement', 'at_placement') then
    if p_mode in ('on_premium_collection', 'over_policy_term') then
      raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % is not implemented (only on_insurer_settlement and at_placement are); refusing rather than recording a mode nothing reads', p_mode;
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
-- 4. The snapshot says which mode is actually in force, and why
-- ---------------------------------------------------------------------
-- Previously it recorded the raw setting. If that setting names a mode with no
-- reader, or gross overrides it, the snapshot must say what the ledger did --
-- otherwise the next reader trusts a value the books never used.
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

    v_basis := new.commission_recognition_override;
    if v_basis is not null then
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

    if v_effective not in ('on_insurer_settlement', 'at_placement') then
      raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % has no reader in this release (implemented: on_insurer_settlement, at_placement). Configure one of those before binding %', v_effective, new.policy_no;
    end if;

    if v_effective = 'at_placement' and coalesce(new.commission_amount, 0) <= 0 then
      raise exception 'INS_COMMISSION_RECOGNITION_MODE: % is set to recognise commission at placement but has no commission; correct the rate or choose on_insurer_settlement', new.policy_no;
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
end $function$;

revoke all on function public.ins_snapshot_bind_config() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. The bind honours the mode
-- ---------------------------------------------------------------------
-- Single-insurer net path first: under at_placement the commission is earned on
-- the bind date against the entry already posted, exactly as the gross path
-- does. Under on_insurer_settlement the entry stays deferred and the settlement
-- trigger earns it, unchanged.
create or replace function public.platform_ins_bind_policy_legacy_impl(p_policy_id uuid)
 returns ins_policies
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_pol         ins_policies%rowtype;
  v_client      ins_clients%rowtype;
  v_client_nm   text;
  v_comm        numeric(18,2);
  v_net         numeric(18,2);
  v_ar_acc      uuid;
  v_ins_acc     uuid;
  v_ar_gl       uuid;
  v_payable_gl  uuid;
  v_unearned_gl uuid;
  v_income_gl   uuid;
  v_commrecv_gl uuid;
  v_lines       jsonb;
  v_je          journal_entries;
  v_desc        text;
  v_basis       text;
  v_gross       boolean;
  v_mode        text;
  v_earn_at_bind boolean;
  v_ev          uuid;
  v_entry       record;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can bind policies' using errcode = '42501';
  end if;

  select * into v_pol from ins_policies where id = p_policy_id for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  perform assert_tenant_access(v_pol.tenant_id);

  if v_pol.status <> 'approved' then
    raise exception 'INS_NOT_APPROVED: policy % is % (submit for approval, then have a manager approve before binding)', v_pol.policy_no, v_pol.status;
  end if;
  if v_pol.gross_premium <= 0 then
    raise exception 'INS_PREMIUM_REQUIRED: enter the gross premium before binding';
  end if;

  v_comm := round(v_pol.gross_premium * v_pol.commission_rate_pct / 100, 2);
  v_net  := v_pol.gross_premium - v_comm;
  if v_net <= 0 then
    raise exception 'INS_COMMISSION_TOO_HIGH: commission would leave nothing to remit to the insurer';
  end if;

  -- Posting roles from the tenant's chart. Missing roles stop the bind.
  v_ar_gl       := get_posting_account(v_pol.tenant_id, 'ar_control');
  v_payable_gl  := get_posting_account(v_pol.tenant_id, 'insurer_payable');
  v_unearned_gl := get_posting_account(v_pol.tenant_id, 'unearned_commission');
  v_income_gl   := get_posting_account(v_pol.tenant_id, 'commission_income');
  if v_ar_gl is null or v_payable_gl is null
     or (v_comm > 0 and (v_unearned_gl is null or v_income_gl is null)) then
    raise exception 'INS_POSTING_RULE_MISSING: the chart of accounts needs ar_control, insurer_payable, unearned_commission and commission_income';
  end if;

  v_basis := public.ins_share_basis(v_pol.id);
  v_gross := (v_basis = 'gross_premium' and v_comm > 0);
  if v_gross then
    v_commrecv_gl := get_posting_account(v_pol.tenant_id, 'commission_receivable');
    if v_commrecv_gl is null then
      raise exception 'INS_POSTING_RULE_MISSING: gross settlement needs a commission_receivable posting rule (the insurer owes the broker its commission)';
    end if;
  end if;

  -- Recognition timing. Gross forces at_placement; otherwise the policy's own
  -- mode decides. Read before the update below so the snapshot and the journal
  -- cannot disagree.
  v_mode := public.ins_commission_recognition_mode(v_pol.id);
  v_earn_at_bind := v_gross or (v_mode = 'at_placement' and v_comm > 0);

  select * into v_client from ins_clients where id = v_pol.client_id;
  select name into v_client_nm from bd_clients where id = v_client.client_id;
  v_ar_acc  := ins_ensure_client_account(v_pol.client_id);
  v_ins_acc := ins_ensure_insurer_account(v_pol.insurer_id);

  v_desc := 'Bind ' || v_pol.policy_no || ' (' || coalesce(v_client_nm, 'client') || ')';

  if v_gross then
    -- The insurer is owed the whole premium; the commission is a separate
    -- claim on that insurer.
    --   debit  client receivable      gross
    --   credit insurer payable        gross
    --   debit  commission receivable  comm
    --   credit commission income      comm
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_ar_gl, 'debit', v_pol.gross_premium, 'currency', v_pol.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_payable_gl, 'credit', v_pol.gross_premium, 'currency', v_pol.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_commrecv_gl, 'debit', v_comm, 'currency', v_pol.currency, 'description', v_desc || ' - commission receivable'),
      jsonb_build_object('gl_account_id', v_income_gl, 'credit', v_comm, 'currency', v_pol.currency, 'description', v_desc || ' - commission earned at placement')
    );
  elsif v_earn_at_bind then
    -- at_placement on a net remittance: the premium will later cross net, so
    -- the commission is earned now and NOT held as unearned.
    --   debit  client receivable      gross
    --   credit insurer payable        net
    --   credit commission income      comm
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_ar_gl, 'debit', v_pol.gross_premium, 'currency', v_pol.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_payable_gl, 'credit', v_net, 'currency', v_pol.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_income_gl, 'credit', v_comm, 'currency', v_pol.currency, 'description', v_desc || ' - commission earned at placement')
    );
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('gl_account_id', v_ar_gl, 'debit', v_pol.gross_premium, 'currency', v_pol.currency, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_payable_gl, 'credit', v_net, 'currency', v_pol.currency, 'description', v_desc)
    );
    if v_comm > 0 then
      v_lines := v_lines || jsonb_build_array(
        jsonb_build_object('gl_account_id', v_unearned_gl, 'credit', v_comm, 'currency', v_pol.currency,
                           'description', v_desc || ' - unearned commission')
      );
    end if;
  end if;

  -- Booked on the inception date (at the inception-date rate), so the period-close
  -- check applies to it.
  v_je := post_journal_entry(v_pol.tenant_id, 'ins_policy_bind', v_pol.id, v_pol.inception_date, v_desc, v_lines);

  perform fin_create_open_item_fx(
    v_pol.tenant_id, v_ar_acc, 'ar_control', 'ins_policy_premium', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_pol.gross_premium,
    'Premium due: ' || v_pol.policy_no, v_pol.currency, v_je.id
  );
  perform fin_create_open_item_fx(
    v_pol.tenant_id, v_ins_acc, 'insurer_payable', 'ins_policy_insurer', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date,
    case when v_gross then v_pol.gross_premium else v_net end,
    case when v_gross then 'Premium payable to insurer: ' || v_pol.policy_no
         else 'Net premium payable to insurer: ' || v_pol.policy_no end,
    v_pol.currency, v_je.id
  );
  if v_gross then
    perform fin_create_open_item_fx(
      v_pol.tenant_id, v_ins_acc, 'commission_receivable', 'ins_commission_receivable', v_pol.id,
      v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_comm,
      'Commission receivable from insurer: ' || v_pol.policy_no, v_pol.currency, v_je.id
    );
  end if;

  if v_comm > 0 then
    insert into ins_commission_entries (tenant_id, policy_id, amount)
    values (v_pol.tenant_id, v_pol.id, v_comm);
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies
     set status = 'active',
         commission_amount = v_comm,
         -- ins_policies_bound_check requires commission + net = gross, so this
         -- column stays arithmetic ("premium less commission") whatever the
         -- basis. Under gross what the broker actually PAYS the insurer is the
         -- full premium, and that is held on the open item, not here.
         net_premium_to_insurer = v_net,
         bound_at = now(),
         bound_by = auth.uid(),
         journal_entry_id = v_je.id
   where id = v_pol.id
  returning * into v_pol;

  if v_pol.renewal_of_id is not null then
    update ins_policies set status = 'renewed'
     where id = v_pol.renewal_of_id and tenant_id = v_pol.tenant_id and status = 'active';
  end if;

  -- Where the mode says the commission is earned now, move the entry to
  -- 'earned' against the bind entry. The income is already on that journal (both
  -- the gross branch and the at_placement branch credit commission_income), so
  -- this is a status change and an event, not a second journal.
  if v_earn_at_bind then
    for v_entry in
      select id, amount from ins_commission_entries
       where policy_id = v_pol.id and tenant_id = v_pol.tenant_id and status = 'deferred'
       for update
    loop
      v_ev := gen_random_uuid();
      insert into ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id)
      values (v_ev, v_pol.tenant_id, v_entry.id, 'recognised', v_entry.amount, v_je.id);

      update ins_commission_entries
         set status = 'earned', earned_on = v_pol.inception_date, updated_at = now()
       where id = v_entry.id;
    end loop;
  end if;

  return v_pol;
end;
$function$;

revoke all on function public.platform_ins_bind_policy_legacy_impl(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. The settlement trigger must not earn what was already earned
-- ---------------------------------------------------------------------
-- It already filters on status = 'deferred', so an at_placement entry is
-- skipped. No change is needed to ins_commission_on_settlement_posted; this
-- comment records that the guard was checked rather than assumed.
--
-- The void path is different: it reverses 'earned' entries when the premium is
-- no longer covered. Under at_placement the entry is earned by the bind, not by
-- a payment, so voiding a settlement must not reverse it. add a flag so the
-- function can tell the two apart.
alter table public.ins_commission_entries
  add column if not exists earned_by text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'ins_commission_entries_earned_by_check'
       and conrelid = 'public.ins_commission_entries'::regclass
  ) then
    alter table public.ins_commission_entries
      add constraint ins_commission_entries_earned_by_check
      check (earned_by is null or earned_by = any (array['placement', 'settlement']));
  end if;
end $$;

comment on column public.ins_commission_entries.earned_by is
  'What recognised this commission: placement (at bind) or settlement (insurer paid). Null on deferred entries and on rows that predate this column.';

-- Backfill: every already-earned row predates at_placement, so it was earned by
-- a settlement.
update public.ins_commission_entries
   set earned_by = 'settlement'
 where status in ('earned', 'transferred') and earned_by is null;

-- The two functions that recognise commission now record how.
create or replace function public.ins_commission_on_settlement_posted()
returns trigger
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
begin
  if exists(select 1 from ins_cancellation_cash_requests where new.id in(settlement_id,to_settlement_id)) then return new; end if;
  if new.direction <> 'out' or new.status <> 'posted' or new.journal_entry_id is null then
    return new;
  end if;

  for r in
    select e.id as entry_id, e.amount, p.policy_no, i.currency as item_currency,
           i.fx_rate as item_rate, i.journal_entry_id as booking_entry
    from fin_allocations al
    join fin_open_items i  on i.id = al.open_item_id and i.source_type in ('ins_policy_insurer','ins_policy_share_insurer','ins_policy_endorsement_insurer')
    join fin_open_item_balances ob on ob.id = i.id
    join ins_commission_entries e on (
          (e.source_open_item_id = i.id)
       or (e.insurer_share_id = i.source_id and i.source_type = 'ins_policy_share_insurer'
           and e.source_open_item_id is null)
       or (e.policy_id = i.source_id and e.insurer_share_id is null
           and i.source_type = 'ins_policy_insurer' and e.source_open_item_id is null)
        ) and e.tenant_id = i.tenant_id
    join ins_policies p on p.id = e.policy_id
    where al.settlement_id = new.id
      -- Only what is still deferred. An at_placement commission was earned at
      -- bind and must not be earned a second time here.
      and e.status = 'deferred'
      and ins_item_paid_amount(i.id) + ob.credited_amount >= i.amount
    order by p.policy_no
    for update of e
  loop
    v_unearned := get_posting_account(new.tenant_id, 'unearned_commission');
    v_income   := get_posting_account(new.tenant_id, 'commission_income');
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: paying the insurer for % earns commission, which needs the unearned_commission and commission_income posting rules', r.policy_no;
    end if;

    v_line  := jsonb_build_object('gl_account_id', v_unearned, 'debit',  r.amount, 'description', 'Commission earned on ' || r.policy_no);
    v_line2 := jsonb_build_object('gl_account_id', v_income,   'credit', r.amount, 'description', 'Commission earned on ' || r.policy_no);
    if r.item_currency is distinct from fin_ledger_currency(new.tenant_id) then
      if r.booking_entry is null or r.item_rate is null or r.item_rate <= 0 then
        raise exception 'INS_COMMISSION_RATE: commission on % has no booked rate; the insurer item must name its booking entry', r.policy_no;
      end if;
      v_line  := v_line  || jsonb_build_object('currency', r.item_currency, 'rate_from_entry', r.booking_entry, 'fx_rate', r.item_rate);
      v_line2 := v_line2 || jsonb_build_object('currency', r.item_currency, 'rate_from_entry', r.booking_entry, 'fx_rate', r.item_rate);
    end if;

    v_ev := gen_random_uuid();
    v_je := post_journal_entry(new.tenant_id, 'ins_commission_recognition', v_ev, new.settlement_date,
      'Commission earned on ' || r.policy_no, jsonb_build_array(v_line, v_line2));

    insert into ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id, settlement_id)
    values (v_ev, new.tenant_id, r.entry_id, 'recognised', r.amount, v_je.id, new.id);

    update ins_commission_entries
       set status = 'earned', earned_on = new.settlement_date, earned_by = 'settlement', updated_at = now()
     where id = r.entry_id;
  end loop;

  return new;
end;
$function$;

revoke all on function public.ins_commission_on_settlement_posted() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Voiding a settlement must not un-earn a placement commission
-- ---------------------------------------------------------------------
-- The void path reverses 'earned' entries whose premium is no longer covered.
-- That is right when the payment is what earned them. An at_placement entry was
-- earned by the bind, and the bind has not been undone -- only the money has
-- moved back. Reversing it would post income then reverse income that was never
-- tied to this payment, and would leave the entry 'deferred' waiting for a
-- second earning that the at_placement journal already put on the books.
--
-- So: reverse only what a settlement earned. A transferred placement commission
-- is still locked, because that money has left for the operating account.
create or replace function public.ins_commission_on_settlement_voided()
returns trigger
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
  v_date     date;
  v_rec_je   uuid;
  v_lines    jsonb;
begin
  if exists(select 1 from ins_cancellation_cash_requests where new.id in(settlement_id,to_settlement_id)) then return new; end if;
  if new.direction <> 'out' or old.status <> 'posted' or new.status <> 'void' then
    return new;
  end if;

  select entry_date into v_date from journal_entries where id = new.void_journal_entry_id;
  v_date := coalesce(v_date, current_date);

  for r in
    select e.id as entry_id, e.amount, e.status as entry_status, e.earned_by,
           p.policy_no, i.currency as item_currency
    from fin_allocations al
    join fin_open_items i  on i.id = al.open_item_id and i.source_type in ('ins_policy_insurer','ins_policy_share_insurer')
    join ins_commission_entries e on ((e.insurer_share_id=i.source_id and i.source_type='ins_policy_share_insurer') or (e.policy_id=i.source_id and e.insurer_share_id is null and i.source_type='ins_policy_insurer')) and e.tenant_id=i.tenant_id
    join ins_policies p on p.id = e.policy_id
    where al.settlement_id = new.id
      and e.status in ('earned', 'transferred')
      and ins_item_paid_amount(i.id) < i.amount
    order by p.policy_no
    for update of e
  loop
    if r.entry_status = 'transferred' then
      raise exception 'INS_COMMISSION_TRANSFERRED: commission on % has already been transferred to the operating account; void that commission transfer first', r.policy_no;
    end if;

    -- Earned at placement: this payment did not earn it, so voiding the payment
    -- does not un-earn it. Skip it entirely -- no journal, no event, no status
    -- change. (Rows that predate earned_by cannot be at_placement, so null here
    -- means a legacy settlement recognition and falls through.)
    if r.earned_by = 'placement' then
      continue;
    end if;

    v_unearned := get_posting_account(new.tenant_id, 'unearned_commission');
    v_income   := get_posting_account(new.tenant_id, 'commission_income');
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: reversing commission on % needs the unearned_commission and commission_income posting rules', r.policy_no;
    end if;

    v_ev := gen_random_uuid();
    if r.item_currency is distinct from fin_ledger_currency(new.tenant_id) then
      select journal_entry_id into v_rec_je
        from ins_commission_events
       where entry_id = r.entry_id and event = 'recognised' and journal_entry_id is not null
       order by created_at desc
       limit 1;
      if v_rec_je is null then
        raise exception 'INS_COMMISSION_RATE: reversing commission on % needs its recognition journal', r.policy_no;
      end if;
      select jsonb_agg(jsonb_build_object(
               'gl_account_id', l.gl_account_id, 'debit', l.credit, 'credit', l.debit,
               'currency', l.currency, 'fx_rate', l.fx_rate, 'is_rounding', l.is_rounding,
               'description', 'Reversal of commission earned on ' || r.policy_no))
        into v_lines
        from journal_entry_lines l
       where l.journal_entry_id = v_rec_je;
      perform set_config('fin.reversal_of', v_rec_je::text, true);
      v_je := post_journal_entry(new.tenant_id, 'ins_commission_recognition_reversal', v_ev, v_date,
        'Commission no longer earned on ' || r.policy_no || ' (settlement voided)', v_lines);
      perform set_config('fin.reversal_of', '', true);
    else
      v_je := post_journal_entry(new.tenant_id, 'ins_commission_recognition_reversal', v_ev, v_date,
        'Commission no longer earned on ' || r.policy_no || ' (settlement voided)',
        jsonb_build_array(
          jsonb_build_object('gl_account_id', v_income,   'debit',  r.amount, 'description', 'Reversal of commission earned on ' || r.policy_no),
          jsonb_build_object('gl_account_id', v_unearned, 'credit', r.amount, 'description', 'Reversal of commission earned on ' || r.policy_no)));
    end if;

    insert into ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id, settlement_id)
    values (v_ev, new.tenant_id, r.entry_id, 'recognition_reversed', r.amount, v_je.id, new.id);

    update ins_commission_entries
       set status = 'deferred', earned_on = null, earned_by = null, updated_at = now()
     where id = r.entry_id;
  end loop;

  return new;
end;
$function$;

revoke all on function public.ins_commission_on_settlement_voided() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. Record how the bind earned it
-- ---------------------------------------------------------------------
-- Both recognisers now stamp earned_by; the bind is handled here so the
-- single-insurer and the shares-and-charges binds share one definition.
create or replace function public.ins_mark_commission_earned_at_placement()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  -- Only fill a blank. The settlement trigger sets earned_by = 'settlement' in
  -- its own UPDATE, and this BEFORE trigger runs on that UPDATE too -- stamping
  -- unconditionally would relabel every settlement-earned row as placement, and
  -- the void path would then refuse to reverse it. (Measured: that is exactly
  -- what broke test_ins_commission and test_foreign_bind_transfer.)
  if new.status = 'earned' and old.status = 'deferred' and new.earned_by is null then
    new.earned_by := 'placement';
  end if;
  return new;
end $function$;

drop trigger if exists trg_ins_commission_earned_by on public.ins_commission_entries;
create trigger trg_ins_commission_earned_by
  before update of status on public.ins_commission_entries
  for each row execute function public.ins_mark_commission_earned_at_placement();

revoke all on function public.ins_mark_commission_earned_at_placement() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. Only now may at_placement be selectable
-- ---------------------------------------------------------------------
-- company_accounting_settings_guard refuses any value not in
-- implemented_values, and the list previously held only
-- on_insurer_settlement. Widening it is done HERE, in the same migration as the
-- reader that honours it (sections 4-8) -- the rule this whole item exists to
-- enforce. on_premium_collection and over_policy_term stay out: nothing reads
-- them, so they remain unselectable rather than silently ignored.
update public.accounting_setting_definitions
   set implemented_values = array['on_insurer_settlement', 'at_placement']
 where key = 'ins.commission_recognition'
   and implemented_values is distinct from array['on_insurer_settlement', 'at_placement'];

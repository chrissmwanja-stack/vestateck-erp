-- =====================================================================
-- Insurance: per-insurer settlement mode (gross vs net) -- Tier 1
-- =====================================================================
--
-- What "per-insurer settlement mode" means here, and what it cannot mean
--
--   gross_premium   The broker remits the WHOLE premium to each insurer and
--                   earns/invoices its commission separately. Cash out per
--                   insurer is gross; commission is a receivable, not a
--                   deduction.
--   net_of_commission  (current behaviour) The broker withholds its commission
--                   and remits net. Commission is earned by remittance.
--
-- The setting is ins.insurer_remittance_basis. It is a LEGAL key
-- (requires_legal_review = true): acct_assert_reviewed refuses to resolve it
-- unless an approved, compliance-reviewed value is in force on the policy's
-- inception date. Today only 'gross_premium' is marked implemented, and until
-- this migration that value did not actually mean gross -- every bind took the
-- net path regardless. That is the gap this closes.
--
-- Tier 1 (this migration) makes gross real for the ordinary single-insurer
-- policy end to end, and -- importantly -- makes the unsupported cases REFUSE
-- LOUDLY instead of silently doing the wrong thing:
--
--   * bind:      a share that is already reviewed and configured is untouched;
--                a new share is written in the mode in force at inception, so
--                the expected remittance is on the record.
--   * settlement: a payment that deviates from the expected basis is refused
--                by name (INS_SETTLEMENT_BASIS) rather than quietly earning
--                commission at the wrong time.
--   * posting:   under gross, commission is earned AT PLACEMENT, because the
--                premium changed hands in full and there is no later event to
--                hang recognition on. Under net, the existing settlement
--                trigger earns it, exactly as before.
--
--   * gross + co-insurance   refused (INS_SETTLEMENT_BASIS_COINSURER)
--   * gross + policy charges refused (INS_SETTLEMENT_BASIS_CHARGES)
--
--   The second and third are Tier 2: they need per-share expected amounts and
--   charges excluded from the insurer-funded amount. Refusing by name is the
--   honest behaviour today; silently netting would be worse.
--
-- Why gross implies at-placement recognition, and the consequence
--
--   Under gross the broker holds the full premium only until it remits, and its
--   commission is a claim on the insurer rather than a withheld amount. There is
--   no premium-collection or remittance event that makes the commission newly
--   real, so deferring it would be fiction. The consequence is that
--   ins.commission_recognition is NOT honoured under gross: a tenant that sets
--   on_premium_collection AND gross_premium gets at-placement, with the reason
--   recorded on the policy snapshot. The settings guard cannot express that
--   interaction (it validates one key at a time), so it is enforced in the bind
--   and stated in the snapshot by ins_snapshot_bind_config (20261117210000),
--   which is the function that owns 'commission_recognition_effective'.
--
--   If an accountant wants deferred recognition and gross settlement together,
--   that is a Tier 2 design (a commission receivable settled on a schedule),
--   not a configuration.
--
-- Server-side only: nothing here reads the browser. The setting is resolved
-- under SECURITY DEFINER and the guards decide.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Record the settlement basis on each insurer share
-- ---------------------------------------------------------------------
-- Null means "no basis recorded" -- rows configured before this migration keep
-- behaving as before (implicitly net at settlement), and get a basis the next
-- time the policy is bound.
alter table public.ins_policy_insurer_shares
  add column if not exists settlement_basis text;

alter table public.ins_policy_insurer_shares
  drop constraint if exists ins_policy_insurer_shares_settlement_basis_check;
alter table public.ins_policy_insurer_shares
  add constraint ins_policy_insurer_shares_settlement_basis_check
  check (settlement_basis is null or settlement_basis in ('gross_premium', 'net_of_commission'));

comment on column public.ins_policy_insurer_shares.settlement_basis is
  'ins.insurer_remittance_basis in force at bind: gross_premium (remit all, '
  'commission invoiced separately) or net_of_commission (withhold commission). '
  'Null on shares configured before 20261117_... Tier 1; settlement with no '
  'basis is guarded by a loud heuristic, never refused silently.';

-- ---------------------------------------------------------------------
-- 2. The resolver
-- ---------------------------------------------------------------------
-- One place that answers "what basis applies to this policy", so bind,
-- settlement and the desk cannot disagree. Inception date, because the
-- setting is resolved as of when the policy was placed.
create or replace function public.ins_share_basis(p_policy_id uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_basis text;
  v_on    date;
  v_res   jsonb;
begin
  -- Prefer the basis recorded at bind, so a later change of setting cannot
  -- rewrite the treatment of a policy already placed.
  select sh.settlement_basis into v_basis
    from public.ins_policy_insurer_shares sh
   where sh.policy_id = p_policy_id and sh.settlement_basis is not null
   limit 1;
  if v_basis is not null then
    return v_basis;
  end if;

  v_on := coalesce((select p.inception_date from public.ins_policies p where p.id = p_policy_id), current_date);
  v_res := public.acct_get_setting('ins.insurer_remittance_basis', v_on);

  -- Nothing approved for this tenant: keep the behaviour every existing book
  -- was built on (commission withheld, remitted net). Refusing here would stop
  -- every bind in every tenant that has not visited the settings screen, which
  -- is not a migration -- it is an outage.
  if v_res ->> 'source' <> 'configured' then
    return 'net_of_commission';
  end if;

  -- A tenant that HAS chosen is held to the legal-review gate.
  return public.acct_assert_reviewed('ins.insurer_remittance_basis', v_on);
end $function$;

revoke all on function public.ins_share_basis(uuid) from public, anon;
grant execute on function public.ins_share_basis(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Bind: write the reviewed basis onto the shares
-- ---------------------------------------------------------------------
-- Both bind paths already compute every amount. This wraps them so the shares
-- carry the mode in force, instead of leaving it to be guessed at settlement.
--
-- Deliberately NOT done: recomputing payable_amount under gross. That is Tier 2
-- (it needs the commission-receivable item and charge handling). Instead the
-- bind refuses gross where Tier 2 has not landed yet, by name.
create or replace function public.ins_bind_settlement_basis_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_basis    text;
  v_shares   integer;
  v_charges  integer;
  v_unearned uuid;
  v_income   uuid;
  v_comm_gl  uuid;
  v_payable  uuid;
  v_gross_premium numeric;
  v_comm_total numeric;
  v_comm     numeric;
  v_je       journal_entries;
  v_entry    record;
  v_ev       uuid;
  v_earn_je  journal_entries;
begin
  -- Only an approved -> active transition binds.
  if not (new.status = 'active' and old.status is distinct from 'active') then
    return new;
  end if;

  v_basis := public.ins_share_basis(new.id);

  select count(*) into v_shares  from public.ins_policy_insurer_shares where policy_id = new.id;
  select count(*) into v_charges from public.ins_policy_charges        where policy_id = new.id;

  if v_basis = 'gross_premium' then
    if v_shares > 1 then
      raise exception 'INS_SETTLEMENT_BASIS_COINSURER: this policy is settled on gross_premium, which is not yet supported for co-insured policies (% insurer shares); switch the remittance basis to net_of_commission or settle the policy as a single insurer', v_shares;
    end if;
    if v_charges > 0 then
      raise exception 'INS_SETTLEMENT_BASIS_CHARGES: this policy is settled on gross_premium, which cannot yet carry policy charges; charges would have to be funded from the client, not the insurer, and that split is not built';
    end if;
  end if;

  -- Record the basis the policy was bound under, so later settlements read it
  -- rather than re-resolving a setting that may have moved since.
  --
  -- Only during a real bind (ins_bind_policy sets ins.binding_policy for the
  -- policy it is binding). INS_FINANCIAL_IMMUTABLE locks shares once a policy is
  -- no longer a draft, and it only lets the bind step of THIS policy through --
  -- so a policy pushed to 'active' by anything else (a fixture, an import) must
  -- not have its shares touched here. Such a policy simply keeps a null basis
  -- and the resolver falls back to the setting at settlement time, which is the
  -- same answer it would have got anyway.
  if coalesce(current_setting('ins.binding_policy', true), '') = new.id::text then
    update public.ins_policy_insurer_shares
       set settlement_basis = v_basis
     where policy_id = new.id and settlement_basis is null;
  end if;

  -- Record the basis itself. The recognition timing it implies is NOT decided
  -- here: this trigger runs after ins_bind_config_snapshot (Postgres fires
  -- same-timing triggers alphabetically, and ins_bind_settlement_basis sorts
  -- after ins_bind_config_snapshot), so writing
  -- 'commission_recognition_effective' here would overwrite the answer the
  -- snapshot trigger just worked out from the policy's own mode
  -- (20261117210000). Settlement basis and recognition mode are separate
  -- questions; each is answered in the place that knows about it.
  new.accounting_config_snapshot :=
    coalesce(new.accounting_config_snapshot, '{}'::jsonb)
    || jsonb_build_object(
         'ins.insurer_remittance_basis', v_basis,
         'settlement_basis_recorded_at', now()
       );
  return new;
end $function$;

revoke all on function public.ins_bind_settlement_basis_guard() from public, anon, authenticated;

drop trigger if exists ins_bind_settlement_basis on public.ins_policies;
create trigger ins_bind_settlement_basis
  before update of status on public.ins_policies
  for each row execute function public.ins_bind_settlement_basis_guard();

-- ---------------------------------------------------------------------
-- 4. Settlement: refuse a payment that contradicts the recorded basis
-- ---------------------------------------------------------------------
-- The existing commission trigger already handles net_of_commission correctly
-- (it earns when the insurer item is fully covered). This guard only adds the
-- basis check, and sits beside it rather than re-implementing it.
-- AFTER, not BEFORE: platform_fin_record_settlement_impl inserts the
-- settlement row first and its allocations afterwards, so a BEFORE trigger
-- always sees zero allocations and would silently pass every payment. Raising
-- here rolls the whole settlement back, which is the same outcome.
drop trigger if exists ins_settlement_basis on public.fin_settlements;

-- The trigger hangs off fin_allocations, not fin_settlements.
--
-- platform_fin_record_settlement_impl inserts the settlement row first and its
-- allocations afterwards. A trigger on fin_settlements -- BEFORE *or* AFTER --
-- cannot see rows the calling function inserted in the same statement (measured:
-- a count of fin_allocations returned 0 from an AFTER trigger that the very next
-- statement had filled). So the check runs where the amount is actually known:
-- one row per allocation of an insurer payable on a posted, outgoing settlement.
create or replace function public.ins_allocation_basis_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  s          fin_settlements%rowtype;
  i          fin_open_items%rowtype;
  v_basis    text;
  v_paid     numeric;
  v_tolerance numeric;
begin
  select * into s from public.fin_settlements where id = new.settlement_id and tenant_id = new.tenant_id;
  raise notice 'ALLOC GUARD item source_type=%', (select source_type from public.fin_open_items where id = new.open_item_id);
  if not found or s.direction <> 'out' or s.status <> 'posted' then
    return new;
  end if;
  -- Cancellation cash has its own workflow and its own guard.
  if exists (select 1 from public.ins_cancellation_cash_requests where s.id in (settlement_id, to_settlement_id)) then
    return new;
  end if;

  select * into i from public.fin_open_items where id = new.open_item_id and tenant_id = new.tenant_id;
  if not found or i.source_type not in ('ins_policy_insurer', 'ins_policy_share_insurer') then
    return new;
  end if;

  select sh.settlement_basis into v_basis
    from public.ins_policy_insurer_shares sh
   where i.source_type = 'ins_policy_share_insurer' and sh.id = i.source_id
   limit 1;

  v_basis := coalesce(
    v_basis,
    public.ins_share_basis(
      case when i.source_type = 'ins_policy_insurer' then i.source_id
           else (select sh2.policy_id from public.ins_policy_insurer_shares sh2 where sh2.id = i.source_id)
      end));

  -- Net basis is NOT guarded here, deliberately.
  --
  -- The net item already holds premium-minus-commission, and the existing
  -- machinery polices it: under-payment leaves the commission deferred, and
  -- over-payment is what a premium refund or an endorsement properly settles.
  -- The insurance tests pay the net item in two instalments and refund against
  -- it, all of which is correct -- a guard comparing the settlement to the item
  -- amount refuses legitimate business (measured: it broke test_ins_commission
  -- and test_foreign_bind_transfer before this comment existed).
  --
  -- The asymmetry is the point: under net a wrong amount is visible as a
  -- commission that never earns, or an item that will not clear. Under gross the
  -- same mistake is invisible, because the item is sized to the full premium and
  -- any part-payment simply looks like a smaller remittance. So only gross is
  -- policed, and it is policed strictly.
  if v_basis <> 'gross_premium' then
    return new;
  end if;

  -- Paid so far INCLUDING this allocation: this trigger fires before the row
  -- exists, so the row itself must be added explicitly. Summing every posted
  -- allocation of the item, not just this settlement's.
  select coalesce(sum(al.amount), 0) + new.amount into v_paid
    from public.fin_allocations al
    join public.fin_settlements st on st.id = al.settlement_id
   where al.open_item_id = i.id
     and st.status = 'posted'
     and al.settlement_id <> new.settlement_id;

  -- Rounding of a fractional-percentage commission must not trip a guard, but a
  -- real basis mistake is never this small.
  v_tolerance := greatest(round(i.amount * 0.01, 2), 0.05);

  -- Under gross the insurer is owed ALL of the premium. Paying materially less
  -- means commission is being withheld on a policy whose basis says it is not,
  -- and the net recognition trigger would never earn it.
  if v_paid < i.amount - v_tolerance then
    raise exception 'INS_SETTLEMENT_BASIS: % is settled on gross_premium (the insurer is owed the full premium), but this payment leaves % unpaid; switch the remittance basis or pay the balance', i.document_no, round(i.amount - v_paid, 2);
  end if;

  return new;
end $function$;

revoke all on function public.ins_allocation_basis_guard() from public, anon, authenticated;

-- Fires after every other allocation guard has accepted the row: the name
-- order puts it last, and it is harmless there -- the exception rolls back the
-- whole settlement either way.
drop trigger if exists ins_allocation_basis on public.fin_allocations;
create trigger ins_allocation_basis
  before insert on public.fin_allocations
  for each row execute function public.ins_allocation_basis_guard();

-- ---------------------------------------------------------------------
-- 5. Bind: gross posts a gross balance sheet, net posts exactly as before
-- ---------------------------------------------------------------------
-- The gross posting cannot be an adjustment after the fact: fin_open_items is
-- immutable (OPEN_ITEM_IMMUTABLE on every update, and an item's amount must be
-- positive), so the insurer payable has to be created at the right amount the
-- first time. That means one function that knows both shapes.
--
-- Below the basis branch, the net path is the previous code unchanged -- which
-- is every policy that exists today.
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

  -- Under gross the commission is earned now: the premium went across in full,
  -- and the income was booked on the bind entry above, so the entry moves to
  -- 'earned' rather than waiting for a remittance. Under net the settlement
  -- trigger earns it later, exactly as before.
  if v_gross then
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

-- Not granted to authenticated: this is an implementation called by the
-- ins_bind_policy wrapper (which is SECURITY DEFINER and owns the right). The
-- baseline grants EXECUTE to PUBLIC on functions by default, and the authz
-- catalog test requires no platform_ins_* be reachable by authenticated.
revoke all on function public.platform_ins_bind_policy_legacy_impl(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Tell the settings screen gross is now real, but only for one insurer
-- ---------------------------------------------------------------------
-- implemented_values is what the guard validates against, so leaving it at
-- ['gross_premium'] would have been true-but-misleading: it is implemented for
-- the single-insurer case and refuses the rest by name. The label carries that.
update public.accounting_setting_definitions
   set label = 'Insurer remittance basis (gross: single-insurer policies only)',
       description = 'Whether the insurer may legally be paid net of commission is not a free '
                  || 'choice. gross_premium remits the full premium and earns commission at '
                  || 'placement; it is refused for co-insured policies and policies with '
                  || 'charges until per-share expected amounts are built.'
 where key = 'ins.insurer_remittance_basis';

-- Endorsements, slice E2: Finance posting of prepared proposals (UGX first)
-- plus the policy-cash and statement integration.
--
-- Money rules (per the approved design):
--   * Additional premium: one journal -- Dr AR control (a new open item with
--     its own booking entry) / Cr insurer payable (a new insurer-share item) /
--     Cr unearned commission (a NEW deferred ins_commission_entries row). The
--     existing recognition trigger earns that entry when the endorsement's
--     own insurer item is fully paid -- no recognition code changes.
--   * Return premium: credit notes against the original items at their booked
--     rates (capped at each item's outstanding; the excess becomes recovery
--     items, the cancellation precedent), and an honest commission clawback:
--     the deferred pool first (Dr unearned), what is already earned or
--     transferred afterwards (Dr commission income). Commission entry rows
--     are never mutated -- each clawback lands in its own ledger table, so a
--     policy can be endorsed (and clawed back) again and again.
--   * A descriptive-only endorsement (premium delta 0) posts nothing: it is
--     numbered and recorded, with no journals and no items.
--   * END- numbering is stamped here, at posting, the way CXL- is stamped at
--     cancellation approval.
--   * The policy row is never touched; statements and the review position
--     compute "current" as bound plus the posted deltas.
--
-- E2 posts in the tenant's functional currency only (INS_ENDORSEMENT_CURRENCY
-- otherwise); the foreign-currency legs are slice E3. A policy with posted
-- endorsements cannot be cancelled until slice E4 teaches the cancellation
-- engine to sweep endorsement items and claw back endorsement commission --
-- refused loudly rather than silently leaving money behind.

-- =============================================================================
-- A. Commission-entry provenance: an endorsement's entry names the endorsement
--    insurer item it was deferred against (source_open_item_id), so the
--    recognition trigger can tell it apart from the policy's own entry.
-- =============================================================================
alter table public.ins_commission_entries
  add column source_open_item_id uuid references public.fin_open_items(id);

-- The posting slice adds its terminal lifecycle event beside E1's set.
alter table public.ins_policy_endorsement_events
  drop constraint ins_policy_endorsement_events_event_check;
alter table public.ins_policy_endorsement_events
  add constraint ins_policy_endorsement_events_event_check
  check (event = any (array['proposed'::text, 'withdrawn'::text, 'prepared'::text,
                            'approved'::text, 'rejected'::text, 'posted'::text]));

comment on column public.ins_commission_entries.source_open_item_id is
  'For endorsement commission: the endorsement insurer item whose full payment earns this entry. Null for the policy''s own bind entry.';

-- The one-entry-per-policy and one-entry-per-share uniques retire here. They
-- guarded a world where a policy could only ever bind once and carry one
-- commission entry; the bind path stays single-shot (the policy state machine
-- refuses a second bind), endorsement entries are now keyed 1:1 to their own
-- insurer item, and the clawback ledger keeps the recurring pool honest.
drop index if exists public.ins_commission_entries_legacy_policy_key;
drop index if exists public.ins_commission_entries_share_key;
create unique index ins_commission_entries_item_key
  on public.ins_commission_entries(source_open_item_id)
  where source_open_item_id is not null;

-- =============================================================================
-- B. The posting journals carry a distinct source type.
-- =============================================================================
alter table public.journal_entries
  drop constraint journal_entries_source_type_check;
alter table public.journal_entries
  add constraint journal_entries_source_type_check check (
    source_type = any (array[
      'supplier_invoice'::text, 'receivable_invoice'::text, 'cash_bank_transaction'::text,
      'opening_balance'::text, 'manual'::text, 'payroll_run'::text,
      'machine_fuel_log'::text, 'machine_maintenance_request'::text,
      'fin_settlement'::text, 'fin_settlement_void'::text,
      'fin_credit_note'::text, 'fin_credit_note_void'::text,
      'ins_policy_bind'::text, 'ins_commission_recognition'::text,
      'ins_commission_recognition_reversal'::text, 'ins_commission_transfer'::text,
      'ins_commission_transfer_void'::text, 'ins_claim_accrual'::text,
      'ins_policy_cancellation'::text, 'ins_cancellation_cash'::text,
      'fx_revaluation'::text, 'fx_revaluation_void'::text,
      'ins_policy_endorsement'::text
    ])
  );

-- =============================================================================
-- C. The clawback ledger: which entry paid for which return, so the pool is
--    computed honestly on the next endorsement too.
-- =============================================================================
create table if not exists public.ins_endorsement_clawbacks (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants(id) on delete cascade,
  endorsement_id      uuid not null references public.ins_policy_endorsements(id),
  commission_entry_id uuid not null references public.ins_commission_entries(id),
  amount              numeric not null check (amount > 0),
  journal_entry_id    uuid,
  created_at          timestamptz not null default now()
);
alter table public.ins_endorsement_clawbacks enable row level security;
revoke all on public.ins_endorsement_clawbacks from public, anon, authenticated, service_role;
grant select on public.ins_endorsement_clawbacks to authenticated;
create policy ins_endorsement_clawbacks_select on public.ins_endorsement_clawbacks
  for select to authenticated
  using (tenant_id = get_my_tenant_id() and can_access_insurance());
select public.apply_tenant_read_only_guard();

-- =============================================================================
-- D. Recognition trigger: endorsement entries earn off their own item; the
--    policy's bind entries keep earning exactly as before.
-- =============================================================================
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
          -- An endorsement entry is earned only by its own insurer item.
          (e.source_open_item_id = i.id)
          -- The policy's bind entries earn off the original items, as before;
          -- provenance-tagged entries are excluded so a later endorsement item
          -- cannot earn them early.
       or (e.insurer_share_id = i.source_id and i.source_type = 'ins_policy_share_insurer'
           and e.source_open_item_id is null)
       or (e.policy_id = i.source_id and e.insurer_share_id is null
           and i.source_type = 'ins_policy_insurer' and e.source_open_item_id is null)
        ) and e.tenant_id = i.tenant_id
    join ins_policies p on p.id = e.policy_id
    where al.settlement_id = new.id
      and e.status = 'deferred'
      -- An item is done when its settlements plus its credit notes cover it:
      -- endorsement returns credit the original items, and a returned premium
      -- must not leave its commission deferred forever.
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
      -- The commission was deferred at the rate the policy was bound at; recognising it
      -- at the same rate keeps the unearned account at zero in base when it empties.
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
       set status = 'earned', earned_on = new.settlement_date, updated_at = now()
     where id = r.entry_id;
  end loop;

  return new;
end;
$function$;

-- =============================================================================
-- E. Policy-cash totals and position learn about endorsement items: money the
--    client paid against an endorsement item counts as collected (it funds
--    remittances), endorsement receivables count as client outstanding, and
--    the position's commission status keeps reading the policy's own entry.
-- =============================================================================
-- (The snapshot-aware shape is preserved exactly: co-insurance policies keep
-- their per-share totals, invoice fee/VAT split and remittance caps; legacy
-- policies keep the bind-era formula. Endorsement money is merged into both.)
create or replace function public.ins_policy_cash_totals(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare sn ins_policy_financial_snapshots%rowtype; v jsonb; sh jsonb; shares jsonb:='[]'; c numeric; due numeric;
 remitted numeric:=0; withdrawn numeric:=0; available numeric:=0; liability numeric:=0; cap numeric:=0;
 endo_c numeric:=0; endo_client numeric:=0; endo_insurer numeric:=0;
begin
 -- Endorsement money rides endorsement-scoped items, not the policy's: the
 -- client's payments against an endorsement item fund remittances all the
 -- same, and an endorsement's receivables and payables are the policy's
 -- outstanding on both sides. (Endorsement payables are settled by generic
 -- settlements, so they display here but are not remittance-capped.)
 select coalesce(sum(a.amount),0) into endo_c
  from ins_policy_endorsements x
  join fin_open_items i on i.source_id=x.id and i.tenant_id=x.tenant_id and i.source_type='ins_policy_endorsement'
  join fin_allocations a on a.open_item_id=i.id and a.tenant_id=i.tenant_id
  join fin_settlements f on f.id=a.settlement_id and f.status='posted' and f.direction='in'
  where x.policy_id=p_policy_id;
 select coalesce(sum(b.outstanding_amount) filter (where b.side='receivable'),0),
        coalesce(sum(b.outstanding_amount) filter (where b.side='payable'),0)
  into endo_client, endo_insurer
  from ins_policy_endorsements x
  join fin_open_item_balances b on b.source_id=x.id and b.tenant_id=x.tenant_id
   and b.source_type in ('ins_policy_endorsement','ins_policy_endorsement_insurer')
  where x.policy_id=p_policy_id;
 select * into sn from ins_policy_financial_snapshots where policy_id=p_policy_id;
 if sn.policy_id is null or not sn.extended then
  v := platform_ins_policy_cash_legacy_totals(p_policy_id);
  v := jsonb_set(v, '{collected}', to_jsonb((v->>'collected')::numeric + endo_c));
  v := jsonb_set(v, '{available_allocated_funds}', to_jsonb(greatest((v->>'available_allocated_funds')::numeric + endo_c, 0)));
  v := jsonb_set(v, '{client_outstanding}', to_jsonb(greatest((v->>'client_outstanding')::numeric + endo_client, 0)));
  v := jsonb_set(v, '{insurer_outstanding}', to_jsonb(greatest((v->>'insurer_outstanding')::numeric + endo_insurer, 0)));
  return v;
 end if;
 select coalesce(sum(a.amount),0) into c from fin_open_items i join fin_allocations a on a.open_item_id=i.id
  join fin_settlements f on f.id=a.settlement_id and f.status='posted' and f.direction='in'
  where i.source_id=p_policy_id and i.source_type='ins_policy_premium';
 select outstanding_amount into due from fin_open_item_balances where source_id=p_policy_id and source_type='ins_policy_premium';
 for sh in select ins_share_cash_totals(s.id)||jsonb_build_object('insurer_name',i.name,'is_lead',s.is_lead) from ins_policy_insurer_shares s
  join ins_insurers i on i.id=s.insurer_id where s.policy_id=p_policy_id order by s.insurer_id
 loop
  shares:=shares||jsonb_build_array(sh); remitted:=remitted+(sh->>'remitted')::numeric;
  withdrawn:=withdrawn+(sh->>'commission_transferred')::numeric; available:=available+(sh->>'available_allocated_funds')::numeric;
  liability:=liability+(sh->>'outstanding')::numeric; cap:=cap+(sh->>'maximum_remittance')::numeric;
 end loop;
 return jsonb_build_object('collected',c+endo_c,'remitted',remitted,'commission_transferred',withdrawn,
  'available_allocated_funds',available+endo_c,
  'insurer_outstanding',liability+endo_insurer,'client_outstanding',coalesce(due,0)+endo_client,
  'maximum_remittance',cap,'shares',shares,
  'invoice_total',sn.invoice_total,'broker_fee_collected',trunc(sn.broker_fee_total*least((c+endo_c)/sn.invoice_total,1),2),
  'vat_collected',trunc(sn.vat_total*least((c+endo_c)/sn.invoice_total,1),2));
end $$;
revoke all on function public.ins_policy_cash_totals(uuid) from public, anon, authenticated;

-- The position wrapper is restored verbatim (the cancelled-policy cash
-- notice and the share caps live there); its delegate already reports a
-- multi-entry commission status, which posted endorsements now produce.
create or replace function public.ins_policy_cash_position(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb;
begin
 v:=platform_ins_cash_position_before_cancellation(p_policy_id);
 if v->>'policy_status'='cancelled' then
  if jsonb_typeof(v->'shares')='array' then v:=jsonb_set(v,'{shares}',coalesce((select jsonb_agg(x||jsonb_build_object('maximum_remittance',0)) from jsonb_array_elements(v->'shares') x),'[]'::jsonb)); end if;
  v:=v||jsonb_build_object('can_prepare',false,'maximum_remittance',0,'cash_notice','Policy cancelled. Use the cancellation-specific recovery/refund workflow; cancellation approval did not authorize cash.'); end if;
 return v;
end $$;

-- =============================================================================
-- F. Statements net the posted endorsements: billed is the bound premium plus
--    every posted endorsement delta; received adds what the client actually
--    paid against endorsement items (settlement allocations, since the policy
--    cash request layer stays about the bind items).
-- =============================================================================
drop view if exists public.ins_client_statement;
create view public.ins_client_statement as
 SELECT p.tenant_id,
    p.id AS policy_id,
    p.policy_no,
    p.client_id,
    bd.name AS client_name,
    p.currency,
    p.gross_premium + coalesce(e.delta, 0::numeric) AS billed_amount,
    COALESCE(r.received, 0::numeric) AS received_amount,
    p.gross_premium + coalesce(e.delta, 0::numeric) - COALESCE(r.received, 0::numeric) AS balance_amount,
    p.bound_at::date AS bound_date,
    p.expiry_date,
    p.status
   FROM ins_policies p
     JOIN ins_clients c ON c.id = p.client_id
     JOIN bd_clients bd ON bd.id = c.client_id
     LEFT JOIN LATERAL (select sum((x.calculation->>'premium_delta')::numeric) as delta
                          from ins_policy_endorsements x
                         where x.tenant_id = p.tenant_id and x.policy_id = p.id
                           and x.status = 'posted') e ON true
     LEFT JOIN LATERAL ( SELECT (select coalesce(sum(q.amount), 0::numeric)
              FROM ins_policy_cash_requests q
             WHERE q.tenant_id = p.tenant_id AND q.policy_id = p.id AND q.kind = 'receipt'::text AND q.status = 'posted'::text)
            + (select coalesce(sum(a.amount), 0::numeric)
                 from ins_policy_endorsements x
                 join fin_open_items oi on oi.source_id = x.id and oi.tenant_id = x.tenant_id
                  and oi.source_type = 'ins_policy_endorsement'
                 join fin_allocations a on a.open_item_id = oi.id and a.tenant_id = oi.tenant_id
                 join fin_settlements s on s.id = a.settlement_id and s.tenant_id = a.tenant_id
                where x.policy_id = p.id and x.tenant_id = p.tenant_id
                  and s.status = 'posted' and s.direction = 'in') AS received) r ON true
  WHERE (p.status = ANY (ARRAY['active'::text, 'renewed'::text])) AND p.tenant_id = get_my_tenant_id() AND can_access_insurance();

revoke all on public.ins_client_statement from public, anon;
grant select on public.ins_client_statement to authenticated, service_role;

-- =============================================================================
-- G. The cross-guard grows its interim rule: a policy with posted endorsements
--    cannot be cancelled until the cancellation engine learns to sweep
--    endorsement items and commission (slice E4).
-- =============================================================================
create or replace function public.ins_endorsement_cross_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if tg_table_name = 'ins_policy_cancellations' then
    if new.status in ('proposed','prepared','posting') and exists (
      select 1 from ins_policy_endorsements
       where policy_id = new.policy_id and status in ('proposed','prepared','posting')
    ) then
      raise exception 'INS_ENDORSEMENT_LIVE: finish or withdraw the live endorsement before cancelling this policy';
    end if;
    if new.status in ('proposed','prepared','posting') and exists (
      select 1 from ins_policy_endorsements
       where policy_id = new.policy_id and status = 'posted'
    ) then
      raise exception 'INS_ENDORSEMENT_POSTED: this policy has posted endorsements; cancelling it needs the endorsement-items extension (E4)';
    end if;
  else
    if new.status in ('proposed','prepared','posting') and exists (
      select 1 from ins_policy_cancellations
       where policy_id = new.policy_id and status in ('proposed','prepared','posting','posted')
    ) then
      raise exception 'INS_CANCELLATION_LIVE: this policy has a cancellation in flight; endorse it another day';
    end if;
  end if;
  return new;
end $function$;

-- =============================================================================
-- H. Finance preparation, posting decision.
-- =============================================================================

-- The posting accounts, validated once at preparation and re-verified at the
-- decision, so a chart-of-accounts change between the two refuses to post.
create or replace function public.ins_endorsement_mappings(p_policy_id uuid, p_clearing_gl_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_tenant uuid;
  v_ar uuid; v_payable uuid; v_unearned uuid; v_income uuid;
begin
  select tenant_id into v_tenant from ins_policies where id = p_policy_id;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  v_ar       := get_posting_account(v_tenant, 'ar_control');
  v_payable  := get_posting_account(v_tenant, 'insurer_payable');
  v_unearned := get_posting_account(v_tenant, 'unearned_commission');
  v_income   := get_posting_account(v_tenant, 'commission_income');
  if v_ar is null or v_payable is null or v_unearned is null or v_income is null then
    raise exception 'INS_ENDORSEMENT_POSTING_RULE_MISSING: the chart of accounts needs ar_control, insurer_payable, unearned_commission and commission_income';
  end if;
  if p_clearing_gl_account_id is null or not exists (
    select 1 from gl_accounts
     where id = p_clearing_gl_account_id and tenant_id = v_tenant
  ) then
    raise exception 'INS_ENDORSEMENT_CLEARING: choose a clearing account from this tenant''s chart of accounts';
  end if;
  return jsonb_build_object(
    'ar', v_ar, 'payable', v_payable, 'unearned', v_unearned,
    'income', v_income, 'clearing', p_clearing_gl_account_id);
end $function$;
revoke all on function public.ins_endorsement_mappings(uuid, uuid) from public, anon, authenticated, service_role;

create or replace function public.ins_prepare_policy_endorsement(p_endorsement_id uuid, p_clearing_gl_account_id uuid)
returns public.ins_policy_endorsements
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  c ins_policy_endorsements%rowtype;
  pid uuid;
  quote jsonb;
  mappings jsonb;
begin
  perform ins_policy_cash_require_finance();
  select policy_id into pid from ins_policy_endorsements
   where id = p_endorsement_id and tenant_id = get_my_tenant_id();
  if not found then raise exception 'INS_NOT_FOUND: endorsement'; end if;
  perform id from ins_policies where id = pid for update;
  select * into c from ins_policy_endorsements where id = p_endorsement_id for update;
  if c.status not in ('proposed','prepared')
     or (c.status = 'prepared' and c.prepared_by <> auth.uid()) then
    raise exception 'INS_ENDORSEMENT_STATE: proposal or own prepared case required';
  end if;
  quote := ins_preview_policy_endorsement(c.policy_id, c.effective_date, c.insurer_terms, c.changes)
           || ins_endorsement_review_position(c.policy_id);
  mappings := ins_endorsement_mappings(c.policy_id, p_clearing_gl_account_id);
  update ins_policy_endorsements
     set status = 'prepared', prepared_by = auth.uid(), prepared_at = now(),
         calculation = quote, accounting_mappings = mappings
   where id = c.id
   returning * into c;
  insert into ins_policy_endorsement_events(tenant_id, endorsement_id, event, actor_id, detail)
  values (c.tenant_id, c.id, 'prepared', auth.uid(),
          jsonb_build_object('calculation', quote, 'mappings', mappings));
  return c;
end $function$;
revoke all on function public.ins_prepare_policy_endorsement(uuid, uuid) from public, anon;
grant execute on function public.ins_prepare_policy_endorsement(uuid, uuid) to authenticated;

create or replace function public.ins_decide_policy_endorsement(
  p_endorsement_id uuid,
  p_decision text,
  p_review_note text,
  p_accept_manual_exception boolean default false
)
returns public.ins_policy_endorsements
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  c ins_policy_endorsements%rowtype;
  p ins_policies%rowtype;
  fresh jsonb; mappings jsonb; share jsonb;
  insurer uuid; v_share_id uuid;
  delta numeric; v_claw numeric; net numeric;
  v_ar uuid; v_payable uuid; v_unearned uuid; v_income uuid; v_clearing uuid;
  v_client_acc uuid; v_ins_acc uuid;
  item fin_open_items%rowtype; created_item fin_open_items%rowtype;
  ce record;
  v_claw_left numeric; v_take numeric; v_claw_lines jsonb := '[]'::jsonb; v_debit_total numeric := 0;
  v_add_lines jsonb := '[]'::jsonb; v_add_items jsonb := '[]'::jsonb;
  v_recos jsonb := '[]'::jsonb; v_todo jsonb;
  v_credit_notes jsonb := '[]'::jsonb; v_new_entries jsonb := '[]'::jsonb;
  v_outstanding numeric; v_applied numeric; v_recovered numeric;
  note_id uuid; note_no text;
  je journal_entries%rowtype; je_adj uuid := null; je_add uuid := null;
  v_first_premium_item uuid := null;
  v_desc text;
begin
  perform ins_policy_cash_require_finance();
  if p_decision not in ('approve','reject') or p_decision is null
     or p_review_note is null or length(btrim(p_review_note)) not between 5 and 2000 then
    raise exception 'INS_ENDORSEMENT_INPUT: decision and detailed Finance review note required';
  end if;
  select policy_id into p.id from ins_policy_endorsements
   where id = p_endorsement_id and tenant_id = get_my_tenant_id();
  if not found then raise exception 'INS_NOT_FOUND: endorsement'; end if;
  select * into p from ins_policies where id = p.id and tenant_id = get_my_tenant_id() for update;
  select * into c from ins_policy_endorsements where id = p_endorsement_id for update;
  if p.status not in ('active','renewed') then
    raise exception 'INS_ENDORSEMENT_STATE: the policy is %; only a bound policy endorses', p.status;
  end if;
  if c.prepared_by = auth.uid() or c.proposed_by = auth.uid() then
    raise exception 'INS_ENDORSEMENT_SELF_APPROVAL: an independent Finance checker is required';
  end if;
  -- An approve retry on a posted case is idempotent only with the same payload.
  if c.status = 'posted' and p_decision = 'approve' and c.checked_by = auth.uid() then
    if c.review_note is distinct from btrim(p_review_note)
       or c.manual_exception_accepted is distinct from coalesce(p_accept_manual_exception, false) then
      raise exception 'INS_ENDORSEMENT_RETRY_CONFLICT: different approval payload';
    end if;
    return c;
  end if;
  if p_decision = 'reject' then
    if c.status not in ('proposed','prepared') then
      raise exception 'INS_ENDORSEMENT_STATE: open proposal required';
    end if;
    update ins_policy_endorsements
       set status = 'rejected', checked_by = auth.uid(), checked_at = now(),
           review_note = btrim(p_review_note)
     where id = c.id
     returning * into c;
    insert into ins_policy_endorsement_events(tenant_id, endorsement_id, event, actor_id, detail)
    values (c.tenant_id, c.id, 'rejected', auth.uid(), jsonb_build_object('note', p_review_note));
    return c;
  end if;
  if c.status <> 'prepared' then
    raise exception 'INS_ENDORSEMENT_STATE: Finance preparation required before approval';
  end if;
  -- Serialize with cash approvals, claims, credits and commission transfers.
  perform m.id from fin_open_items m join ins_policy_cash_items k on k.id = m.id
   where k.source_id = p.id and k.tenant_id = p.tenant_id order by m.id for update of m;
  perform e.id from ins_commission_entries e where e.policy_id = p.id order by e.id for update;
  fresh := ins_preview_policy_endorsement(p.id, c.effective_date, c.insurer_terms, c.changes)
           || ins_endorsement_review_position(p.id);
  if exists(select 1 from accounting_periods
             where tenant_id = p.tenant_id and status = 'closed'
               and current_date between period_start and period_end) then
    raise exception 'INS_ENDORSEMENT_PERIOD: current accounting period closed';
  end if;
  -- live_endorsements carries the case's own lifecycle state (proposed ->
  -- prepared between maker and checker), not amounts; the one-live rule means
  -- it cannot hide a competitor. Everything else in the recompute must match.
  if (fresh - 'generated_at' - 'live_endorsements') is distinct from (c.calculation - 'generated_at' - 'live_endorsements') then
    raise exception 'INS_ENDORSEMENT_STALE: amounts or collection position changed; Finance maker must refresh preparation';
  end if;
  -- requires_review lives per share (a share delta bigger than that share's
  -- whole premium); any share flagging demands the checker's explicit nod.
  if exists (select 1 from jsonb_array_elements(fresh -> 'shares') sh
              where (sh ->> 'requires_review')::boolean)
     and not coalesce(p_accept_manual_exception, false) then
    raise exception 'INS_ENDORSEMENT_EXCEPTION: explicit independent Finance acceptance of the reviewed calculation required';
  end if;
  mappings := ins_endorsement_mappings(p.id, (c.accounting_mappings ->> 'clearing')::uuid);
  if mappings is distinct from c.accounting_mappings then
    raise exception 'INS_ENDORSEMENT_STALE: accounting mappings changed';
  end if;
  -- E2 posts in the tenant's functional currency only; foreign legs are E3.
  if p.currency is distinct from fin_ledger_currency(p.tenant_id) then
    raise exception 'INS_ENDORSEMENT_CURRENCY: posting lands in % first; a % endorsement waits for the foreign slice',
      fin_ledger_currency(p.tenant_id), p.currency;
  end if;

  update ins_policy_endorsements
     set status = 'posting', checked_by = auth.uid(), checked_at = now(),
         review_note = btrim(p_review_note),
         manual_exception_accepted = coalesce(p_accept_manual_exception, false),
         posting_date = current_date,
         endorsement_no = next_doc_number(c.tenant_id, 'ins_policy_endorsement', 'END'),
         operation_txid = txid_current()
   where id = c.id
   returning * into c;

  v_ar       := (mappings ->> 'ar')::uuid;
  v_payable  := (mappings ->> 'payable')::uuid;
  v_unearned := (mappings ->> 'unearned')::uuid;
  v_income   := (mappings ->> 'income')::uuid;
  v_clearing := (mappings ->> 'clearing')::uuid;
  v_client_acc := ins_ensure_client_account(p.client_id);
  v_desc := 'Endorsement ' || c.endorsement_no || ' on ' || p.policy_no;

  for share in select value from jsonb_array_elements(fresh -> 'shares') loop
    insurer := (share ->> 'insurer_id')::uuid;
    delta   := (share ->> 'premium_delta')::numeric;
    continue when delta = 0;
    v_claw  := (share ->> 'commission_delta')::numeric;
    select id into v_share_id from ins_policy_insurer_shares
     where policy_id = p.id and tenant_id = p.tenant_id and insurer_id = insurer
     order by id limit 1;
    v_ins_acc := ins_ensure_insurer_account(insurer);

    if delta > 0 then
      ---------------------------------------------------------------
      -- Additional premium: AR item + insurer-share item + a new
      -- deferred commission entry tied to the endorsement's own item.
      ---------------------------------------------------------------
      net := delta - v_claw;
      if net <= 0 then
        raise exception 'INS_ENDORSEMENT_COMMISSION: commission would leave nothing to remit to the insurer';
      end if;
      v_add_lines := v_add_lines || jsonb_build_array(
        jsonb_build_object('gl_account_id', v_ar, 'debit', delta, 'currency', p.currency, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_payable, 'credit', net, 'currency', p.currency, 'description', v_desc)
      );
      if v_claw > 0 then
        v_add_lines := v_add_lines || jsonb_build_object(
          'gl_account_id', v_unearned, 'credit', v_claw, 'currency', p.currency,
          'description', v_desc || ' - unearned commission');
      end if;
      v_add_items := v_add_items || jsonb_build_object(
        'insurer_id', insurer, 'share_id', v_share_id, 'premium', delta,
        'net', net, 'commission', v_claw);
    else
      ---------------------------------------------------------------
      -- Return premium: credit notes at the booked rates, capped at
      -- each original item's outstanding; honest clawback of the
      -- commission (deferred pool first, then what is earned).
      ---------------------------------------------------------------
      v_claw := -v_claw;  -- the claw is a positive amount on a return
      -- Client side: the original premium item is policy-level.
      select * into item from fin_open_items
       where tenant_id = p.tenant_id and source_type = 'ins_policy_premium' and source_id = p.id;
      if not found then raise exception 'INS_ENDORSEMENT_HISTORY: original premium item missing'; end if;
      select outstanding_amount into v_outstanding from fin_open_item_balances where id = item.id;
      v_applied := least(v_outstanding, -delta);
      if v_applied > 0 then
        note_id := gen_random_uuid();
        note_no := next_doc_number(c.tenant_id, 'fin_credit_note', 'CRN');
        insert into fin_credit_notes(id, tenant_id, credit_note_no, side, control_role, party_account_id,
                                     offset_gl_account_id, amount, currency, fx_rate, realised_result,
                                     credit_date, reason, reference)
        values (note_id, c.tenant_id, note_no, item.side, item.control_role, item.party_account_id,
                v_clearing, v_applied, p.currency, 1, 0, current_date, c.reason, c.endorsement_no);
        insert into fin_credit_applications(tenant_id, credit_note_id, open_item_id, amount)
        values (c.tenant_id, note_id, item.id, v_applied);
        je := post_journal_entry(c.tenant_id, 'fin_credit_note', note_id, current_date,
          'Endorsement credit ' || c.endorsement_no || ': ' || p.policy_no,
          jsonb_build_array(
            jsonb_build_object('gl_account_id', v_clearing, 'debit', v_applied),
            jsonb_build_object('gl_account_id', (mappings ->> 'ar')::uuid, 'credit', v_applied)));
        update fin_credit_notes set journal_entry_id = je.id where id = note_id;
        v_credit_notes := v_credit_notes || jsonb_build_object(
          'note_id', note_id, 'open_item_id', item.id, 'amount', v_applied, 'side', item.side);
      end if;
      v_recovered := (-delta) - v_applied;
      if v_recovered > 0 then
        -- The return exceeds the billed premium still outstanding: the client
        -- owes the difference back (the cancellation engine's recovery item).
        v_recos := v_recos || jsonb_build_object(
          'party', item.party_account_id, 'role', 'ar_control', 'source_type',
          'ins_policy_endorsement_recovery', 'source_id', c.id, 'amount', v_recovered);
      end if;
      -- Insurer side: mirror the share's net reduction against its item.
      net := (-delta) - v_claw;
      -- The ORIGINAL bind items: pinned by their booking journal (the policy's
      -- bind entry), so a prior additional endorsement's items never match.
      if v_share_id is not null then
        select i.* into item from fin_open_items i join ins_policy_cash_items k on k.id = i.id
         where k.source_id = p.id and k.source_type = 'ins_policy_insurer'
           and k.insurer_share_id = v_share_id and k.tenant_id = p.tenant_id
           and i.journal_entry_id = p.journal_entry_id;
      else
        select i.* into item from fin_open_items i join ins_policy_cash_items k on k.id = i.id
         where k.source_id = p.id and k.source_type = 'ins_policy_insurer'
           and k.insurer_share_id is null and i.party_account_id = v_ins_acc
           and i.journal_entry_id = p.journal_entry_id and k.tenant_id = p.tenant_id;
      end if;
      if not found then raise exception 'INS_ENDORSEMENT_HISTORY: original insurer item missing'; end if;
      select outstanding_amount into v_outstanding from fin_open_item_balances where id = item.id;
      v_applied := least(v_outstanding, net);
      if v_applied > 0 then
        note_id := gen_random_uuid();
        note_no := next_doc_number(c.tenant_id, 'fin_credit_note', 'CRN');
        insert into fin_credit_notes(id, tenant_id, credit_note_no, side, control_role, party_account_id,
                                     offset_gl_account_id, amount, currency, fx_rate, realised_result,
                                     credit_date, reason, reference)
        values (note_id, c.tenant_id, note_no, item.side, item.control_role, item.party_account_id,
                v_clearing, v_applied, p.currency, 1, 0, current_date, c.reason, c.endorsement_no);
        insert into fin_credit_applications(tenant_id, credit_note_id, open_item_id, amount)
        values (c.tenant_id, note_id, item.id, v_applied);
        je := post_journal_entry(c.tenant_id, 'fin_credit_note', note_id, current_date,
          'Endorsement credit ' || c.endorsement_no || ': ' || p.policy_no,
          jsonb_build_array(
            jsonb_build_object('gl_account_id', (mappings ->> 'payable')::uuid, 'debit', v_applied),
            jsonb_build_object('gl_account_id', v_clearing, 'credit', v_applied)));
        update fin_credit_notes set journal_entry_id = je.id where id = note_id;
        v_credit_notes := v_credit_notes || jsonb_build_object(
          'note_id', note_id, 'open_item_id', item.id, 'amount', v_applied, 'side', item.side);
      end if;
      v_recovered := net - v_applied;
      if v_recovered > 0 then
        v_recos := v_recos || jsonb_build_object(
          'party', item.party_account_id, 'role', 'ar_control', 'source_type',
          'ins_policy_endorsement_recovery_insurer', 'source_id', c.id, 'amount', v_recovered);
      end if;
      -- Commission clawback: the deferred pool first, then earned, then
      -- transferred; the rows are never mutated, the ledger records the take.
      v_claw_left := v_claw;
      for ce in
        select e.id, e.amount, e.status,
               (e.amount - coalesce((select sum(x.amount) from ins_endorsement_clawbacks x
                                      where x.commission_entry_id = e.id and x.tenant_id = e.tenant_id), 0)) as available
          from ins_commission_entries e
         where e.policy_id = p.id and e.tenant_id = p.tenant_id
           and case when v_share_id is not null
                    then e.insurer_share_id = v_share_id
                    else e.insurer_share_id is null end
         order by case e.status when 'deferred' then 0 when 'earned' then 1 else 2 end,
                  e.created_at, e.id
      loop
        exit when v_claw_left <= 0;
        v_take := least(v_claw_left, greatest(ce.available, 0));
        continue when v_take <= 0;
        v_claw_lines := v_claw_lines || jsonb_build_object(
          'gl_account_id', case when ce.status = 'deferred' then v_unearned else v_income end,
          'debit', v_take, 'currency', p.currency,
          'description', v_desc || ' - commission clawback');
        insert into ins_endorsement_clawbacks(id, tenant_id, endorsement_id, commission_entry_id, amount)
        values (gen_random_uuid(), c.tenant_id, c.id, ce.id, v_take);
        v_claw_left := v_claw_left - v_take;
      end loop;
      if v_claw_left > 0 then
        raise exception 'INS_ENDORSEMENT_HISTORY: the policy''s commission cannot cover this clawback';
      end if;
    end if;
  end loop;

  -- The return-side adjustments journal: clawback debits, clearing balance.
  if jsonb_array_length(v_claw_lines) > 0 then
    v_debit_total := (select coalesce(sum((l ->> 'debit')::numeric), 0) from jsonb_array_elements(v_claw_lines) l);
    je := post_journal_entry(c.tenant_id, 'ins_policy_endorsement', c.id, current_date,
      v_desc || ': commission clawback',
      v_claw_lines || jsonb_build_object('gl_account_id', v_clearing, 'credit', v_debit_total));
    je_adj := je.id;
  end if;
  -- Recovery items name the adjustments journal (created after posting, the
  -- cancellation pattern).
  for v_todo in select * from jsonb_array_elements(v_recos) loop
    created_item := fin_create_open_item_fx(c.tenant_id, (v_todo ->> 'party')::uuid,
      (v_todo ->> 'role'), (v_todo ->> 'source_type'), (v_todo ->> 'source_id')::uuid,
      c.endorsement_no, current_date, current_date, (v_todo ->> 'amount')::numeric,
      'Endorsement recovery: ' || p.policy_no, p.currency, je_adj);
  end loop;
  -- The additional-side journal, then one client item for the whole
  -- endorsement, and per-insurer payable items. Each insurer item is keyed by
  -- its deferred commission entry (created first, naming the item once it
  -- exists): when that item is fully paid, the recognition trigger earns
  -- exactly that entry.
  if jsonb_array_length(v_add_lines) > 0 then
    je := post_journal_entry(c.tenant_id, 'ins_policy_endorsement', c.id, current_date, v_desc, v_add_lines);
    je_add := je.id;
    created_item := fin_create_open_item_fx(c.tenant_id, v_client_acc, 'ar_control',
      'ins_policy_endorsement', c.id, c.endorsement_no, current_date, current_date,
      (select sum((v ->> 'premium')::numeric) from jsonb_array_elements(v_add_items) v),
      'Endorsement premium due: ' || p.policy_no, p.currency, je_add);
    v_first_premium_item := created_item.id;
  end if;
  for v_todo in select * from jsonb_array_elements(v_add_items) loop
    -- The commission entry is born first (open items are immutable, so the
    -- item must carry its final source at birth); the item then carries the
    -- entry's id as its source, and the entry names the item whose full
    -- payment earns it.
    if (v_todo ->> 'commission')::numeric > 0 then
      insert into ins_commission_entries(id, tenant_id, policy_id, amount, status, insurer_share_id)
      values (gen_random_uuid(), c.tenant_id, p.id, (v_todo ->> 'commission')::numeric, 'deferred',
              (v_todo ->> 'share_id')::uuid)
      returning id into note_id;
      v_new_entries := v_new_entries || to_jsonb(note_id);
    else
      note_id := null;
    end if;
    created_item := fin_create_open_item_fx(c.tenant_id,
      ins_ensure_insurer_account((v_todo ->> 'insurer_id')::uuid), 'insurer_payable',
      'ins_policy_endorsement_insurer', note_id, c.endorsement_no, current_date, current_date,
      (v_todo ->> 'net')::numeric, 'Net premium payable to insurer: ' || p.policy_no, p.currency, je_add);
    if note_id is not null then
      update ins_commission_entries set source_open_item_id = created_item.id where id = note_id;
    end if;
  end loop;

  update ins_policy_endorsements
     set status = 'posted',
         journal_entry_id = coalesce(je_adj, je_add),
         premium_item_id = v_first_premium_item,
         credit_note_ids = v_credit_notes,
         commission_entry_ids = v_new_entries,
         operation_txid = null
   where id = c.id
   returning * into c;
  insert into ins_policy_endorsement_events(tenant_id, endorsement_id, event, actor_id, detail)
  values (c.tenant_id, c.id, 'posted', auth.uid(), jsonb_build_object(
    'review_note', p_review_note,
    'manual_exception_accepted', coalesce(p_accept_manual_exception, false),
    'adjustment_journal', je_adj, 'additional_journal', je_add,
    'credit_notes', v_credit_notes));
  return c;
end $function$;
revoke all on function public.ins_decide_policy_endorsement(uuid, text, text, boolean) from public, anon;
grant execute on function public.ins_decide_policy_endorsement(uuid, text, text, boolean) to authenticated;

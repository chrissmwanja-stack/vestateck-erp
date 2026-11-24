-- =====================================================================
-- Claim stage model and the two review states
-- Accountant pack v2, decision 3 (B5); pack section 7.2-7.3
-- =====================================================================
-- The pack asks for eight stages -- reported, assessed, internally approved,
-- insurer confirmed, funded, partially paid, fully paid, closed -- plus two states,
-- Coverage under review and Payment disputed, and says that internal approval alone
-- never posts.
--
-- This does NOT rename ins_claims.status, and the reason is worth recording.
--
-- The existing vocabulary (notified, assessing, approved, settled, repudiated,
-- closed) is used by ten functions, including void_journal_entry() and
-- ins_cancelled_policy_guard(), which are not claim code. Rewriting a status
-- domain across all of them in one unreplayed migration is how a payments system
-- breaks quietly. It is also unnecessary: every one of the eight stages is
-- derivable from data that already exists, because ins_claim_payments.kind
-- already separates 'insurer_receipt' (funding) from 'insurer_direct' and
-- 'client_payout' (payment to the claimant). So the stage is computed, not stored:
--
--   reported            status = notified
--   assessed            status = assessing
--   internally_approved status = approved and not yet recognised
--   insurer_confirmed   status = approved and recognised_at set
--   funded              a posted insurer_receipt exists
--   partially_paid      0 < posted payments to the claimant < approved_amount
--   fully_paid          posted payments to the claimant >= approved_amount
--   closed              status = closed
--   repudiated          status = repudiated  (v2 section 7.2 lists eight stages and
--                       omits repudiation; the state exists and is required, so it
--                       is kept and reported rather than dropped)
--
-- The two review states ARE stored, because they cannot be derived: coverage is a
-- judgement someone makes, and a payment is disputed by a person, not by a total.
--
-- Also built here, because the pack requires it and the current code refuses it:
-- pack 7.3 says a claim registered after expiry is accepted where the insured event
-- occurred during cover, and flagged for review rather than rejected. ins_create_claim
-- hard-rejects a loss date outside the policy period. It now accepts one with an
-- explicit acknowledgement and a reason, and records it as late.

-- ---------------------------------------------------------------------
-- 1. The two review states, and late registration
-- ---------------------------------------------------------------------
alter table ins_claims
  add column if not exists review_state text,
  add column if not exists review_note text,
  add column if not exists late_notification boolean not null default false,
  add column if not exists insurer_notified_date date,
  add column if not exists insurer_acknowledged_date date;

alter table ins_claims drop constraint if exists ins_claims_review_state_check;
alter table ins_claims add constraint ins_claims_review_state_check
  check (review_state is null or review_state in ('coverage_under_review', 'payment_disputed'));

-- A review state has to say why. "Under review" with no reason is not an audit trail.
alter table ins_claims drop constraint if exists ins_claims_review_note_check;
alter table ins_claims add constraint ins_claims_review_note_check
  check (review_state is null
         or (review_note is not null and length(btrim(review_note)) >= 5));

-- A late registration must be explainable too.
alter table ins_claims drop constraint if exists ins_claims_late_notification_check;
alter table ins_claims add constraint ins_claims_late_notification_check
  check (not late_notification or (review_note is not null and length(btrim(review_note)) >= 5));

comment on column ins_claims.review_state is
  'Pack v2 section 7.2 review state: coverage_under_review or payment_disputed. A review state never blocks the claim existing; it blocks recognising insurer liability before confirmation.';
comment on column ins_claims.late_notification is
  'True when the claim was recorded outside the policy period (pack v2 section 7.3). Accepted and flagged, never auto-rejected.';

-- The review state changes value: it must go through the claim functions, exactly
-- like status and the amounts, or the audit row and the state can disagree.
create or replace function public.ins_claims_guard() returns trigger
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
begin
  if tg_op = 'INSERT' then
    if not public.ins_via_rpc() then
      raise exception 'INS_RPC_ONLY: create claims with ins_create_claim()' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.claim_no is distinct from old.claim_no or new.policy_id is distinct from old.policy_id then
    raise exception 'INS_IMMUTABLE: a claim number and its policy cannot be changed';
  end if;
  if not public.ins_via_rpc() and (
    new.status is distinct from old.status
    or new.approved_amount is distinct from old.approved_amount
    or new.paid_amount is distinct from old.paid_amount
    or new.settled_at is distinct from old.settled_at
    or new.payment_mode is distinct from old.payment_mode
    or new.reserve_amount is distinct from old.reserve_amount
    or new.review_state is distinct from old.review_state
    or new.late_notification is distinct from old.late_notification
  ) then
    raise exception 'INS_CLAIM_RPC_ONLY: status, amounts, reserve, review state and payment mode change through the claim functions' using errcode = '42501';
  end if;

  if new.loss_date is distinct from old.loss_date and not exists (
    select 1 from ins_policies p
     where p.id = new.policy_id and p.tenant_id = new.tenant_id
       and new.loss_date between p.inception_date and p.expiry_date
  ) then
    raise exception 'INS_LOSS_OUTSIDE_POLICY: loss date % is outside the policy period', new.loss_date;
  end if;

  -- Pack v2 section 7.3: while coverage is under review, "no insurer liability is
  -- recognised before confirmation". Recognition is the moment 1120 and 2030 are
  -- created, so it is refused here rather than only in the RPC, which would leave
  -- any future caller free to do it.
  if new.recognised_at is distinct from old.recognised_at
     and new.review_state = 'coverage_under_review' then
    raise exception 'INS_CLAIM_REVIEW: claim % is under coverage review; the insurer liability cannot be recognised until the review is resolved', new.claim_no;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. ins_create_claim: accept a late registration, flagged
-- ---------------------------------------------------------------------
-- Signature extended with two trailing defaulted arguments, so every existing
-- positional caller keeps working unchanged.
create or replace function public.ins_create_claim(
  p_policy_id uuid,
  p_loss_date date,
  p_notified_date date,
  p_loss_description text,
  p_insurer_claim_ref text default null::text,
  p_reserve_amount numeric default 0,
  p_accept_out_of_period boolean default false,
  p_late_reason text default null::text
) returns ins_claims
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_pol    ins_policies%rowtype;
  v_row    ins_claims%rowtype;
  v_outside boolean;
  v_late    boolean;
  v_note    text := nullif(btrim(p_late_reason), '');
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  select * into v_pol from ins_policies where id = p_policy_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  if v_pol.status = 'draft' then
    raise exception 'INS_CLAIM_STATE: a claim needs a bound policy';
  end if;
  if nullif(btrim(p_loss_description), '') is null then
    raise exception 'INS_REQUIRED: describe the loss';
  end if;
  if coalesce(p_reserve_amount, 0) < 0 then
    raise exception 'INS_AMOUNT: reserve cannot be negative';
  end if;

  -- Pack 7.3: an event outside the period, or a registration after expiry, is
  -- flagged for review rather than rejected -- but only with an explicit
  -- acknowledgement and a stated reason, and only an insurance manager may give it.
  v_outside := p_loss_date < v_pol.inception_date or p_loss_date > v_pol.expiry_date;
  v_late := coalesce(p_notified_date, current_date) > v_pol.expiry_date;

  if v_outside then
    if not coalesce(p_accept_out_of_period, false) then
      raise exception 'INS_LOSS_OUTSIDE_POLICY: loss date % is outside the policy period % to %. Register it with p_accept_out_of_period and a reason if the insured event should still be considered.',
        p_loss_date, v_pol.inception_date, v_pol.expiry_date;
    end if;
    if not can_manage_insurance() then
      raise exception 'INS_FORBIDDEN: accepting a loss outside the policy period needs insurance manager authority' using errcode = '42501';
    end if;
    if v_note is null then
      raise exception 'INS_NOTE_REQUIRED: say why a loss outside the policy period is being considered';
    end if;
  end if;

  if (v_outside or v_late) and v_note is null then
    raise exception 'INS_NOTE_REQUIRED: a claim registered outside the policy period needs a reason';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_claims (
    tenant_id, claim_no, policy_id, status, loss_date, notified_date,
    loss_description, insurer_claim_ref, reserve_amount,
    review_state, review_note, late_notification
  ) values (
    v_tenant, next_doc_number(v_tenant, 'INS_CLAIM', 'CLM', 5), v_pol.id, 'notified', p_loss_date,
    coalesce(p_notified_date, current_date), btrim(p_loss_description),
    nullif(btrim(p_insurer_claim_ref), ''), coalesce(p_reserve_amount, 0),
    case when v_outside then 'coverage_under_review' else null end,
    v_note,
    (v_outside or v_late)
  )
  returning * into v_row;

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_row.id, null, 'notified',
          case when v_outside or v_late
               then 'Claim notified outside the policy period: ' || v_note
               else 'Claim notified' end);
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Driving the two review states
-- ---------------------------------------------------------------------
create or replace function public.ins_set_claim_review_state(
  p_claim_id uuid,
  p_state text,
  p_note text
) returns ins_claims
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if p_state is not null and p_state not in ('coverage_under_review', 'payment_disputed') then
    raise exception 'INS_CLAIM_REVIEW: review state must be coverage_under_review, payment_disputed, or null to clear it (got %)', p_state;
  end if;
  if p_state is not null and nullif(btrim(p_note), '') is null then
    raise exception 'INS_NOTE_REQUIRED: give the reason for the review state';
  end if;

  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  if v_claim.status in ('closed', 'settled') and p_state is not null then
    raise exception 'INS_CLAIM_STATE: a % claim cannot be put back under review', v_claim.status;
  end if;

  -- Clearing a disputed payment is a decision, not a correction.
  if v_claim.review_state is not null and p_state is null and not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: clearing a review state needs insurance manager authority' using errcode = '42501';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update ins_claims
     set review_state = p_state,
         review_note = case when p_state is null then null else btrim(p_note) end
   where id = v_claim.id
  returning * into v_claim;

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_claim.tenant_id, v_claim.id, v_claim.status, v_claim.status,
          case when p_state is null
               then 'Review state cleared: ' || coalesce(nullif(btrim(p_note), ''), 'no note')
               else 'Review state set to ' || p_state || ': ' || btrim(p_note) end);
  return v_claim;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. The stage, computed from what already exists
-- ---------------------------------------------------------------------
create or replace function public.ins_claim_stage(p_claim_id uuid)
returns text
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  with c as (
    select cl.*,
           coalesce((select sum(p.amount) from ins_claim_payments p
                      where p.claim_id = cl.id and p.tenant_id = cl.tenant_id
                        and p.status = 'posted'
                        and p.kind in ('insurer_direct', 'client_payout')), 0) as paid,
           exists (select 1 from ins_claim_payments p
                    where p.claim_id = cl.id and p.tenant_id = cl.tenant_id
                      and p.status = 'posted' and p.kind = 'insurer_receipt') as funded
      from ins_claims cl
     where cl.id = p_claim_id and cl.tenant_id = get_my_tenant_id()
  )
  select case
    when review_state = 'payment_disputed'  then 'payment_disputed'
    when review_state = 'coverage_under_review' then 'coverage_under_review'
    when status = 'notified'   then 'reported'
    when status = 'assessing'  then 'assessed'
    when status = 'repudiated' then 'repudiated'
    when status = 'closed'     then 'closed'
    when status in ('approved', 'settled') then
      case
        when coalesce(approved_amount, 0) > 0 and paid >= approved_amount then 'fully_paid'
        when paid > 0 then 'partially_paid'
        when funded then 'funded'
        when recognised_at is not null then 'insurer_confirmed'
        else 'internally_approved'
      end
    else status
  end
  from c
$$;

comment on function public.ins_claim_stage(uuid) is
  'Pack v2 section 7.2 stage for a claim, computed from status, recognition and posted payments. Nothing is stored, so the stage cannot drift from the ledger.';

-- ---------------------------------------------------------------------
-- 5. Record the insurer''s notification and acknowledgement dates
-- ---------------------------------------------------------------------
-- Pack 7.3 asks for incident date, client notification, insurer notification and
-- insurer acknowledgement to be recorded on a late claim. loss_date and
-- notified_date already exist; these are the other two.
create or replace function public.ins_set_claim_insurer_dates(
  p_claim_id uuid,
  p_insurer_notified date,
  p_insurer_acknowledged date
) returns ins_claims
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  if p_insurer_notified is not null and p_insurer_notified < v_claim.loss_date then
    raise exception 'INS_CLAIM_DATES: the insurer cannot be notified before the loss (%)', v_claim.loss_date;
  end if;
  if p_insurer_acknowledged is not null and p_insurer_notified is not null
     and p_insurer_acknowledged < p_insurer_notified then
    raise exception 'INS_CLAIM_DATES: the insurer cannot acknowledge before it was notified';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update ins_claims
     set insurer_notified_date = coalesce(p_insurer_notified, insurer_notified_date),
         insurer_acknowledged_date = coalesce(p_insurer_acknowledged, insurer_acknowledged_date)
   where id = v_claim.id
  returning * into v_claim;
  return v_claim;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Exposure
-- ---------------------------------------------------------------------
revoke all on function public.ins_set_claim_review_state(uuid, text, text) from public;
revoke all on function public.ins_claim_stage(uuid) from public;
revoke all on function public.ins_set_claim_insurer_dates(uuid, date, date) from public;

grant execute on function public.ins_set_claim_review_state(uuid, text, text) to authenticated;
grant execute on function public.ins_claim_stage(uuid) to authenticated;
grant execute on function public.ins_set_claim_insurer_dates(uuid, date, date) to authenticated;

-- ins_create_claim gained two defaulted arguments; keep the old 6-argument form
-- callable so nothing that already calls it positionally has to change.
do $$
begin
  raise notice 'ins_create_claim now accepts p_accept_out_of_period and p_late_reason; calls passing six arguments are unchanged';
end $$;

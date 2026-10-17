-- Phase B, claims: segregation of duties on approval, and un-approval before recognition.
--
-- Decisions (owner's answers, PROPOSED for the accountant to confirm):
--   1. The person who registered a claim (ins_claims.created_by) cannot approve it.
--      Only that one person is kept apart; recognition and payment are not restricted.
--   2. An approved claim can be un-approved (back to 'assessing') only while nothing has
--      been recognised and nothing has been paid. A reason is required. Nothing is
--      reversed, because nothing was posted. Once a receivable is recognised, or any
--      payment is recorded, un-approval is refused.
--
-- The rest of ins_transition_claim is unchanged from 20261016190000_ins_claim_recognition.sql.

create or replace function public.ins_transition_claim(
  p_claim_id uuid,
  p_to       text,
  p_note     text default null,
  p_amount   numeric default null
)
returns public.ins_claims
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant     uuid := get_my_tenant_id();
  v_claim      ins_claims%rowtype;
  v_from       text;
  v_sum        numeric;
  v_insurer    uuid;
  v_client     uuid;
  v_mode       text;
  v_legal      boolean;
  v_live_pays  integer;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  v_from := v_claim.status;

  if p_to in ('approved', 'settled', 'repudiated', 'closed') and not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers decide claims' using errcode = '42501';
  end if;

  v_legal := (v_from, p_to) in (
    ('notified', 'assessing'), ('notified', 'repudiated'),
    ('assessing', 'approved'), ('assessing', 'repudiated'),
    ('approved', 'settled'), ('approved', 'assessing'),
    ('settled', 'closed'), ('repudiated', 'closed')
  );
  if not v_legal then
    raise exception 'INS_CLAIM_TRANSITION: a claim cannot move from % to %', v_from, p_to;
  end if;

  if p_to = 'repudiated' and nullif(btrim(p_note), '') is null then
    raise exception 'INS_NOTE_REQUIRED: give the reason for repudiating the claim';
  end if;

  -- Un-approval: manager only, reason required, and only before anything was recognised or paid.
  if v_from = 'approved' and p_to = 'assessing' then
    if not can_manage_insurance() then
      raise exception 'INS_FORBIDDEN: only insurance admins and managers un-approve claims' using errcode = '42501';
    end if;
    if nullif(btrim(p_note), '') is null then
      raise exception 'INS_NOTE_REQUIRED: give the reason for un-approving the claim';
    end if;
    if v_claim.recognised_at is not null then
      raise exception 'INS_CLAIM_RECOGNISED: this claim''s receivable is recognised, so it cannot be un-approved';
    end if;
    select count(*) into v_live_pays from ins_claim_payments
     where claim_id = v_claim.id and tenant_id = v_tenant and voided_at is null;
    if v_claim.paid_amount <> 0 or v_live_pays > 0 then
      raise exception 'INS_CLAIM_PAID: this claim has payments recorded, so it cannot be un-approved';
    end if;
  end if;

  -- Segregation of duties: the registrant cannot approve their own claim.
  if p_to = 'approved' and v_claim.created_by is not null and v_claim.created_by = auth.uid() then
    raise exception 'INS_SEGREGATION: the person who registered this claim cannot approve it; another manager must';
  end if;

  perform set_config('ins.via_rpc', 'on', true);

  if p_to = 'approved' then
    if p_amount is null or p_amount <= 0 then
      raise exception 'INS_AMOUNT: approved amount must be greater than zero';
    end if;
    select p.sum_insured, p.insurer_id, p.client_id into v_sum, v_insurer, v_client
      from ins_policies p where p.id = v_claim.policy_id;
    if v_sum > 0 and p_amount > v_sum then
      raise exception 'INS_AMOUNT: approved amount exceeds the policy sum insured';
    end if;
    select i.claim_payment_mode into v_mode from ins_insurers i where i.id = v_insurer and i.tenant_id = v_tenant;
    v_mode := coalesce(v_mode, 'insurer_direct');

    -- Approval does not create a receivable or payable. For a brokerage-managed claim
    -- the claim is 'approved, pending settlement' until ins_recognise_claim_receivable.
    update ins_claims set status = 'approved', approved_amount = p_amount, payment_mode = v_mode
     where id = v_claim.id returning * into v_claim;
  elsif p_to = 'assessing' and v_from = 'approved' then
    -- Un-approval clears the decision. Nothing was posted, so nothing needs reversing.
    update ins_claims set status = 'assessing', approved_amount = null, payment_mode = null
     where id = v_claim.id returning * into v_claim;
  elsif p_to = 'settled' then
    if v_claim.paid_amount < coalesce(v_claim.approved_amount, 0) then
      raise exception 'INS_CLAIM_PAYMENT_REQUIRED: a claim settles when its payments cover the approved amount; record the payments instead';
    end if;
    update ins_claims set status = 'settled', settled_at = coalesce(settled_at, now())
     where id = v_claim.id returning * into v_claim;
  else
    update ins_claims set status = p_to
     where id = v_claim.id returning * into v_claim;
  end if;

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_claim.id, v_from, p_to, nullif(btrim(p_note), ''));
  return v_claim;
end;
$$;

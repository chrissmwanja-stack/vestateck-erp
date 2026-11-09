-- Phase B, claims: approval is not recognition.
--
-- Accountant answer 20: approval does not by itself establish the brokerage's right to
-- receive from the insurer or its obligation to pay the claimant. A brokerage-managed
-- claim is 'approved, pending settlement' until the recognition criteria are met.
--
-- Decision in this migration (PROPOSED, not yet approved by the accountant): the
-- criteria are the insurer's written confirmation that it will pay the brokerage. The
-- reference to that confirmation is required and stored on the claim history.
--
-- What changes
--   1. ins_claims.recognised_at / recognised_by. Backfilled for brokerage-managed claims
--      already approved: their accrual was posted at approval, so they count as recognised.
--   2. ins_transition_claim no longer posts at approval.
--   3. ins_recognise_claim_receivable posts the same accrual as before, on recognition.
--   4. ins_record_claim_receipt and ins_record_claim_payout refuse until recognised.
--
-- Not changed: posted accruals are not reversed. Un-approving a claim is still not
-- supported (see 20261013090000).

alter table public.ins_claims add column if not exists recognised_at timestamptz;
alter table public.ins_claims add column if not exists recognised_by uuid;

-- Existing brokerage-managed approvals were accrued at approval, so they are recognised.
update public.ins_claims
   set recognised_at = updated_at
 where payment_mode = 'via_broker'
   and status in ('approved', 'settled', 'closed')
   and recognised_at is null;

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
  v_recv_gl    uuid;
  v_pay_gl     uuid;
  v_ins_acc    uuid;
  v_cli_acc    uuid;
  v_desc       text;
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
    ('approved', 'settled'),
    ('settled', 'closed'), ('repudiated', 'closed')
  );
  if not v_legal then
    raise exception 'INS_CLAIM_TRANSITION: a claim cannot move from % to %', v_from, p_to;
  end if;

  if p_to = 'repudiated' and nullif(btrim(p_note), '') is null then
    raise exception 'INS_NOTE_REQUIRED: give the reason for repudiating the claim';
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

create or replace function public.ins_record_claim_receipt(
  p_claim_id        uuid,
  p_bank_account_id uuid,
  p_amount          numeric,
  p_receipt_date    date,
  p_reference       text default null,
  p_notes           text default null
)
returns public.ins_claim_payments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_kind   text;
  v_item   record;
  v_set    fin_settlements%rowtype;
  v_pay    ins_claim_payments%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers record claim receipts' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_NOT_FOUND: claim'; end if;
  if v_claim.status <> 'approved' then
    raise exception 'INS_CLAIM_STATE: receipts are recorded on an approved claim (this one is %)', v_claim.status;
  end if;
  if v_claim.payment_mode <> 'via_broker' then
    raise exception 'INS_CLAIM_MODE: this insurer pays the client directly; record the insurer payment instead';
  end if;
  if v_claim.recognised_at is null then
    raise exception 'INS_CLAIM_NOT_RECOGNISED: record the insurer''s confirmation first, so the receivable is recognised';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_AMOUNT: the receipt amount must be greater than zero';
  end if;
  select kind into v_kind from fin_bank_accounts where id = p_bank_account_id and tenant_id = v_tenant;
  if v_kind is distinct from 'client_money' then
    raise exception 'INS_BANK_KIND: claim money is received into a client-money bank account';
  end if;

  select b.id, b.party_account_id, b.outstanding_amount into v_item
    from fin_open_item_balances b
   where b.tenant_id = v_tenant and b.source_type = 'ins_claim_insurer' and b.source_id = v_claim.id;
  if not found then raise exception 'INS_NOT_FOUND: the insurer item for this claim'; end if;
  if p_amount > v_item.outstanding_amount then
    raise exception 'INS_AMOUNT: the insurer still owes only % on this claim', v_item.outstanding_amount;
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  v_set := platform_fin_record_settlement_impl(
    v_tenant, p_bank_account_id, 'in', v_item.party_account_id, p_amount, p_receipt_date,
    jsonb_build_array(jsonb_build_object('open_item_id', v_item.id, 'amount', p_amount)),
    coalesce(nullif(btrim(p_reference), ''), v_claim.claim_no), nullif(btrim(p_notes), ''));

  insert into ins_claim_payments (tenant_id, claim_id, kind, amount, payment_date, reference, notes, settlement_id)
  values (v_tenant, v_claim.id, 'insurer_receipt', p_amount, p_receipt_date, nullif(btrim(p_reference), ''), nullif(btrim(p_notes), ''), v_set.id)
  returning * into v_pay;
  return v_pay;
end;
$$;

create or replace function public.ins_record_claim_payout(
  p_claim_id        uuid,
  p_bank_account_id uuid,
  p_amount          numeric,
  p_payment_date    date,
  p_reference       text default null,
  p_notes           text default null
)
returns public.ins_claim_payments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant   uuid := get_my_tenant_id();
  v_claim    ins_claims%rowtype;
  v_kind     text;
  v_item     record;
  v_held     numeric;
  v_set      fin_settlements%rowtype;
  v_pay      ins_claim_payments%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers pay out claims' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_NOT_FOUND: claim'; end if;
  if v_claim.status <> 'approved' then
    raise exception 'INS_CLAIM_STATE: payouts are made on an approved claim (this one is %)', v_claim.status;
  end if;
  if v_claim.payment_mode <> 'via_broker' then
    raise exception 'INS_CLAIM_MODE: this insurer pays the client directly; there is nothing for the brokerage to pay out';
  end if;
  if v_claim.recognised_at is null then
    raise exception 'INS_CLAIM_NOT_RECOGNISED: record the insurer''s confirmation first, so the payable is recognised';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_AMOUNT: the payout amount must be greater than zero';
  end if;
  select kind into v_kind from fin_bank_accounts where id = p_bank_account_id and tenant_id = v_tenant;
  if v_kind is distinct from 'client_money' then
    raise exception 'INS_BANK_KIND: claim money is paid out of a client-money bank account';
  end if;

  select coalesce(sum(amount) filter (where kind = 'insurer_receipt'), 0)
         - coalesce(sum(amount) filter (where kind = 'client_payout'), 0)
    into v_held
    from ins_claim_payments where claim_id = v_claim.id and status = 'posted';
  if p_amount > v_held then
    raise exception 'INS_CLAIM_FUNDS_NOT_RECEIVED: only % has been received from the insurer and not yet paid out; the brokerage does not pay a client ahead of the insurer', v_held;
  end if;

  select b.id, b.party_account_id, b.outstanding_amount into v_item
    from fin_open_item_balances b
   where b.tenant_id = v_tenant and b.source_type = 'ins_claim_client' and b.source_id = v_claim.id;
  if not found then raise exception 'INS_NOT_FOUND: the client item for this claim'; end if;
  if p_amount > v_item.outstanding_amount then
    raise exception 'INS_AMOUNT: only % is still owed to the client on this claim', v_item.outstanding_amount;
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  v_set := platform_fin_record_settlement_impl(
    v_tenant, p_bank_account_id, 'out', v_item.party_account_id, p_amount, p_payment_date,
    jsonb_build_array(jsonb_build_object('open_item_id', v_item.id, 'amount', p_amount)),
    coalesce(nullif(btrim(p_reference), ''), v_claim.claim_no), nullif(btrim(p_notes), ''));

  insert into ins_claim_payments (tenant_id, claim_id, kind, amount, payment_date, reference, notes, settlement_id)
  values (v_tenant, v_claim.id, 'client_payout', p_amount, p_payment_date, nullif(btrim(p_reference), ''), nullif(btrim(p_notes), ''), v_set.id)
  returning * into v_pay;

  perform ins_claim_apply_payment_totals(v_claim.id, 'Paid in full to the client by the brokerage');
  return v_pay;
end;
$$;

-- Recognition of the insurer receivable and the client payable (brokerage-managed claims).
create or replace function public.ins_recognise_claim_receivable(p_claim_id uuid, p_insurer_confirmation text)
returns public.ins_claims
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_insurer uuid;
  v_client  uuid;
  v_recv_gl uuid;
  v_pay_gl  uuid;
  v_ins_acc uuid;
  v_cli_acc uuid;
  v_desc    text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers recognise claim receivables' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  if v_claim.status <> 'approved' then
    raise exception 'INS_CLAIM_STATE: only an approved claim can be recognised (this one is %)', v_claim.status;
  end if;
  if v_claim.payment_mode <> 'via_broker' then
    raise exception 'INS_CLAIM_MODE: only a claim paid through the brokerage is recognised here';
  end if;
  if v_claim.recognised_at is not null then
    raise exception 'INS_CLAIM_RECOGNISED: this claim is already recognised';
  end if;
  if nullif(btrim(p_insurer_confirmation), '') is null then
    raise exception 'INS_NOTE_REQUIRED: give the insurer''s written confirmation reference before recognising the receivable';
  end if;

  select p.insurer_id, p.client_id into v_insurer, v_client from ins_policies p where p.id = v_claim.policy_id;
  v_recv_gl := get_posting_account(v_tenant, 'insurer_claim_receivable');
  v_pay_gl  := get_posting_account(v_tenant, 'client_claim_payable');
  if v_recv_gl is null or v_pay_gl is null then
    raise exception 'INS_POSTING_RULE_MISSING: this insurer pays claims through the brokerage, so the chart of accounts needs insurer_claim_receivable and client_claim_payable';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  v_ins_acc := ins_ensure_insurer_account(v_insurer);
  v_cli_acc := ins_ensure_client_account(v_client);
  v_desc := 'Claim ' || v_claim.claim_no || ' recognised: insurer confirmed payment through the brokerage';
  perform post_journal_entry(v_tenant, 'ins_claim_accrual', v_claim.id, current_date, v_desc, jsonb_build_array(
    jsonb_build_object('gl_account_id', v_recv_gl, 'debit',  v_claim.approved_amount, 'description', v_desc),
    jsonb_build_object('gl_account_id', v_pay_gl,  'credit', v_claim.approved_amount, 'description', v_desc)));
  perform fin_create_open_item(v_tenant, v_ins_acc, 'insurer_claim_receivable', 'ins_claim_insurer', v_claim.id,
    v_claim.claim_no, current_date, current_date, v_claim.approved_amount, 'Claim funds due from the insurer');
  perform fin_create_open_item(v_tenant, v_cli_acc, 'client_claim_payable', 'ins_claim_client', v_claim.id,
    v_claim.claim_no, current_date, current_date, v_claim.approved_amount, 'Claim proceeds due to the client');

  update ins_claims set recognised_at = now(), recognised_by = auth.uid()
   where id = v_claim.id returning * into v_claim;
  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_claim.id, 'approved', 'approved', 'Receivable recognised. Insurer confirmation: ' || btrim(p_insurer_confirmation));
  return v_claim;
end;
$$;

revoke all on function public.ins_recognise_claim_receivable(uuid, text) from public, anon;
grant execute on function public.ins_recognise_claim_receivable(uuid, text) to authenticated;

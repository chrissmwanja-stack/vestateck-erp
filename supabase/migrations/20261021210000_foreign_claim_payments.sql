-- The last unproven money path in a foreign currency: claim receipts and
-- payouts. Recognition, receipts and payouts were already currency-true by
-- construction (recognition accrues in the policy currency with booking
-- entries; the payments delegate to the 3c settlement engine, which pins
-- the settlement to the bank account's currency and the item's booked
-- rate) -- but nothing had walked a USD claim end to end, and the payout
-- anti-fronting check summed receipt and payout amounts across currencies.
-- This migration fixes that arithmetic: held funds are counted per
-- currency, so only money that arrived in the payout account's currency
-- satisfies a payout from it.
--
-- Test: supabase/tests/test_foreign_claims.sql.

CREATE OR REPLACE FUNCTION public.ins_record_claim_payout(p_claim_id uuid, p_bank_account_id uuid, p_amount numeric, p_payment_date date, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS ins_claim_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- Held funds are counted per currency: only money that arrived in this
  -- account's currency satisfies a payout from it. The settlement engine
  -- refuses a cross-currency payout outright (SETTLEMENT_CURRENCY); this
  -- keeps the anti-fronting arithmetic honest when a claim ever carries
  -- payments in more than one currency.
  select coalesce(sum(p.amount) filter (where p.kind = 'insurer_receipt'), 0)
         - coalesce(sum(p.amount) filter (where p.kind = 'client_payout'), 0)
    into v_held
    from ins_claim_payments p
   where p.claim_id = v_claim.id
     and p.status = 'posted'
     and (select s.currency from fin_settlements s where s.id = p.settlement_id)
       = (select b.currency from fin_bank_accounts b where b.id = p_bank_account_id);
  if p_amount > v_held then
    raise exception 'INS_CLAIM_FUNDS_NOT_RECEIVED: only % has been received from the insurer in this account''s currency and not yet paid out; the brokerage does not pay a client ahead of the insurer', v_held;
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
$function$


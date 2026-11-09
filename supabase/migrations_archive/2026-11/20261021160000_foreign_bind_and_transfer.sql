-- Phase A, A3 slice 3d-2 (see docs/insurance-brokerage/CURRENCY_REVIEW.md): policies may
-- bind in a foreign currency, and commission moves with the rates it was booked at.
--
-- What changes:
--   1. INS_CURRENCY_UNSUPPORTED is gone from both bind paths. The bind journal posts in
--      the policy's currency at the approved inception-date rate, and the premium and
--      insurer items are created with the booking entry (fin_create_open_item_fx), so
--      they carry the rate the policy was bound at. Functional-currency policies post
--      line for line as before.
--   2. Commission transfers between bank accounts still require both accounts in the same
--      currency (a conversion is a bank payment, not a transfer), and now also require the
--      commission's policies to be in that currency. The client-money side is credited at
--      the rate each policy was bound at (naming the bind entry as its rate source), the
--      operating side debited at the transfer-date rate, and the difference booked as
--      realised gain or loss, so the trust account nets to zero in the currency and in
--      base. The trust sufficiency check is per currency.
--   3. The commission recognition triggers carry the item's currency: recognition posts
--      unearned-to-income at the rate the item was booked at (naming its booking entry),
--      and a voided settlement reverses the recognition journal exactly (reversal mode).
--      Functional-currency recognition is unchanged.
--   4. Claim recognition accrues in the policy's currency and creates its two claim items
--      with the accrual journal as their booking entry.
--   5. The cancellation pipeline stays functional-currency for now (slice 3d-3): a guard
--      on ins_policy_cancellations refuses a proposal for a policy in another currency
--      (INS_CANCELLATION_CURRENCY) instead of letting it post mis-rated journals. The
--      cash and credit functions behind it are only reachable through a proposal.
--
-- Still open in slice 3: the cancellation pipeline itself, then period-end revaluation
-- (3e), then the UGX column defaults and the 8-versus-10-decimal rate question.

-- =====================================================================
-- A. Bind, legacy path (single insurer, header rate)
-- =====================================================================
create or replace function public.platform_ins_bind_policy_legacy_impl(p_policy_id uuid)
 returns ins_policies
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_pol        ins_policies%rowtype;
  v_client     ins_clients%rowtype;
  v_client_nm  text;
  v_comm       numeric(18,2);
  v_net        numeric(18,2);
  v_ar_acc     uuid;
  v_ins_acc    uuid;
  v_ar_gl      uuid;
  v_payable_gl uuid;
  v_unearned_gl uuid;
  v_income_gl  uuid;
  v_lines      jsonb;
  v_je         journal_entries;
  v_desc       text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can bind policies' using errcode = '42501';
  end if;

  select * into v_pol from ins_policies where id = p_policy_id for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  perform assert_tenant_access(v_pol.tenant_id);

  if v_pol.status <> 'draft' then
    raise exception 'INS_NOT_DRAFT: policy % is already %', v_pol.policy_no, v_pol.status;
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

  select * into v_client from ins_clients where id = v_pol.client_id;
  select name into v_client_nm from bd_clients where id = v_client.client_id;
  v_ar_acc  := ins_ensure_client_account(v_pol.client_id);
  v_ins_acc := ins_ensure_insurer_account(v_pol.insurer_id);

  v_desc := 'Bind ' || v_pol.policy_no || ' (' || coalesce(v_client_nm, 'client') || ')';
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

  -- Booked on the inception date (at the inception-date rate), so the period-close
  -- check applies to it.
  v_je := post_journal_entry(v_pol.tenant_id, 'ins_policy_bind', v_pol.id, v_pol.inception_date, v_desc, v_lines);

  -- The items carry the policy's currency and the bind entry, so they hold the rate the
  -- policy was bound at (fin_create_open_item_fx takes the rate from that entry's
  -- control line; for the functional currency this is the old behaviour plus the entry).
  perform fin_create_open_item_fx(
    v_pol.tenant_id, v_ar_acc, 'ar_control', 'ins_policy_premium', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_pol.gross_premium,
    'Premium due: ' || v_pol.policy_no, v_pol.currency, v_je.id
  );
  perform fin_create_open_item_fx(
    v_pol.tenant_id, v_ins_acc, 'insurer_payable', 'ins_policy_insurer', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_net,
    'Net premium payable to insurer: ' || v_pol.policy_no, v_pol.currency, v_je.id
  );

  if v_comm > 0 then
    insert into ins_commission_entries (tenant_id, policy_id, amount)
    values (v_pol.tenant_id, v_pol.id, v_comm);
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies
     set status = 'active',
         commission_amount = v_comm,
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

  return v_pol;
end;
$function$;

-- =====================================================================
-- B. Bind, insurer shares + charges path
-- =====================================================================
create or replace function public.platform_ins_bind_policy_risk_legacy_impl(p_policy_id uuid)
 returns ins_policies
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare p ins_policies%rowtype; s ins_policy_insurer_shares%rowtype; c ins_policy_charges%rowtype;
 n integer; leads integer; pct numeric; extended boolean; premium_used numeric:=0; part numeric;
 comm numeric:=0; payable numeric:=0; fees numeric:=0; vat numeric:=0; total numeric; ar uuid; insurer_account uuid;
 ar_gl uuid; pay_gl uuid; unearned_gl uuid; income_gl uuid; vat_gl uuid; lines jsonb; je journal_entries%rowtype; snap jsonb;
begin
 if not can_manage_insurance() then raise exception 'INS_FORBIDDEN: Insurance manager required' using errcode='42501'; end if;
 select * into p from ins_policies where id=p_policy_id for update;
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 perform assert_tenant_access(p.tenant_id);
 if p.status<>'draft' then raise exception 'INS_NOT_DRAFT: policy'; end if;
 select count(*),count(*) filter(where is_lead),sum(share_pct) into n,leads,pct from ins_policy_insurer_shares where policy_id=p.id;
 extended:=n>1 or exists(select 1 from ins_policy_charges where policy_id=p.id);
 if n>0 then
  if pct<>100 or leads<>1 then raise exception 'INS_SHARE_TOTAL: exactly 100%% and one lead required'; end if;
  if exists(select 1 from ins_policy_insurer_shares sh join ins_insurers i on i.id=sh.insurer_id where sh.policy_id=p.id and (not sh.reviewed or not i.is_active)) then
    raise exception 'INS_CONFIG_REVIEW: review every insurer share before binding';
  end if;
  if p.insurer_id is distinct from (select insurer_id from ins_policy_insurer_shares where policy_id=p.id and is_lead) then
    raise exception 'INS_SHARE_LEAD: policy insurer must match the configured lead';
  end if;
 end if;
 if not extended then
   if n=1 then
    if (select commission_rate_pct from ins_policy_insurer_shares where policy_id=p.id) is distinct from p.commission_rate_pct then
     raise exception 'INS_LEGACY_RATE: the single-insurer path uses the policy header rate (maximum two decimals)'; end if;
    update ins_policy_insurer_shares set premium_amount=p.gross_premium,pass_through_amount=0,commission_amount=round(p.gross_premium*p.commission_rate_pct/100,2),
     payable_amount=p.gross_premium-round(p.gross_premium*p.commission_rate_pct/100,2) where policy_id=p.id;
   end if;
   -- This function body, its journal and its TWO open items are unchanged.
   p:=platform_ins_bind_policy_legacy_impl(p.id);
   insert into ins_policy_financial_snapshots(policy_id,tenant_id,extended,invoice_total,broker_fee_total,vat_total,snapshot,journal_entry_id,bound_by)
   values(p.id,p.tenant_id,false,p.gross_premium,0,0,jsonb_build_object('policy',to_jsonb(p),'shares',coalesce((select jsonb_agg(to_jsonb(x)) from ins_policy_insurer_shares x where policy_id=p.id),'[]'::jsonb),'charges','[]'::jsonb,'open_items',(select jsonb_agg(to_jsonb(i)) from fin_open_items i where i.source_id=p.id and i.source_type in('ins_policy_premium','ins_policy_insurer'))),p.journal_entry_id,auth.uid());
   return p;
 end if;
 if p.gross_premium<=0 then raise exception 'INS_CONFIG_INPUT: positive premium required'; end if;
 if exists(select 1 from ins_policy_charges where policy_id=p.id and (not reviewed or amount is null)) then
   raise exception 'INS_CONFIG_REVIEW: review charges and enter current amounts, including an explicit zero where intended';
 end if;
 if n=0 then raise exception 'INS_SHARE_REQUIRED: charges require insurer configuration'; end if;
 -- Largest-remainder allocation: exact cents, closest proportional amounts,
 -- deterministic insurer-ID tie-breaks; the lead has no rounding privilege.
 with amounts as (
  select id,insurer_id,trunc(p.gross_premium*share_pct/100,2) as base,
   p.gross_premium*share_pct/100-trunc(p.gross_premium*share_pct/100,2) as fraction
  from ins_policy_insurer_shares where policy_id=p.id
 ), ranked as(select *,row_number() over(order by fraction desc,insurer_id) as rank,
  round((p.gross_premium-sum(base) over())*100) as cents from amounts)
 update ins_policy_insurer_shares sh set premium_amount=r.base+case when r.rank<=r.cents then .01 else 0 end,
  pass_through_amount=0 from ranked r where sh.id=r.id;
 if exists(select 1 from ins_policy_insurer_shares where policy_id=p.id and premium_amount<=0) then
  raise exception 'INS_SHARE_TOO_SMALL: every insurer needs at least one cent of premium'; end if;
 update ins_policy_insurer_shares set commission_amount=round(premium_amount*commission_rate_pct/100,2) where policy_id=p.id;
 select sum(premium_amount) into premium_used from ins_policy_insurer_shares where policy_id=p.id;
 for c in select * from ins_policy_charges where policy_id=p.id order by id loop
   if c.kind='broker_fee' then
     fees:=fees+c.amount;
     part:=case c.vat_mode when 'exclusive' then round(c.amount*c.vat_rate_pct/100,2) else 0 end;
     vat:=vat+part;
     update ins_policy_charges set vat_amount=part where id=c.id;
   elsif c.recipient_mode='one_insurer' then
     update ins_policy_insurer_shares set pass_through_amount=pass_through_amount+c.amount where policy_id=p.id and insurer_id=c.recipient_insurer_id;
     if not found then raise exception 'INS_CHARGE_RECIPIENT: recipient does not participate'; end if;
   else
     with amounts as (
      select id,insurer_id,trunc(c.amount*share_pct/100,2) as base,
       c.amount*share_pct/100-trunc(c.amount*share_pct/100,2) as fraction
      from ins_policy_insurer_shares where policy_id=p.id
     ), ranked as(select *,row_number() over(order by fraction desc,insurer_id) as rank,
      round((c.amount-sum(base) over())*100) as cents from amounts)
     update ins_policy_insurer_shares sh set pass_through_amount=sh.pass_through_amount+r.base+case when r.rank<=r.cents then .01 else 0 end
      from ranked r where sh.id=r.id;
   end if;
 end loop;
 update ins_policy_insurer_shares set payable_amount=premium_amount-commission_amount+pass_through_amount where policy_id=p.id;
 select sum(commission_amount),sum(payable_amount) into comm,payable from ins_policy_insurer_shares where policy_id=p.id;
 total:=p.gross_premium+coalesce((select sum(amount) from ins_policy_charges where policy_id=p.id),0)+vat;
 if premium_used<>p.gross_premium or total<>payable+comm+fees+vat then raise exception 'INS_FINANCIAL_TOTAL: allocation does not reconcile'; end if;
 ar_gl:=get_posting_account(p.tenant_id,'ar_control'); pay_gl:=get_posting_account(p.tenant_id,'insurer_payable');
 unearned_gl:=get_posting_account(p.tenant_id,'unearned_commission'); income_gl:=get_posting_account(p.tenant_id,'commission_income');
 vat_gl:=get_posting_account(p.tenant_id,'vat_output');
 if ar_gl is null or pay_gl is null or (comm>0 and (unearned_gl is null or income_gl is null))
    or (vat>0 and vat_gl is null) then raise exception 'INS_POSTING_RULE_MISSING: configure receivables, insurer payable, commission and (when charged) vat_output'; end if;
 if exists(select 1 from ins_policy_charges chg where chg.policy_id=p.id and chg.kind='broker_fee' and chg.amount>0
   and not exists(select 1 from gl_accounts g where g.id=chg.income_gl_account_id and g.tenant_id=p.tenant_id and g.account_type='revenue' and g.is_active)) then
   raise exception 'INS_POSTING_RULE_MISSING: each broker fee needs an explicit active revenue account'; end if;
 if vat>0 and not exists(select 1 from gl_accounts where id=vat_gl and tenant_id=p.tenant_id and account_type='liability' and is_active) then raise exception 'INS_POSTING_RULE_MISSING: vat_output must map to active tax liability'; end if;
 ar:=ins_ensure_client_account(p.client_id);
 lines:=jsonb_build_array(jsonb_build_object('gl_account_id',ar_gl,'debit',total,'currency',p.currency),jsonb_build_object('gl_account_id',pay_gl,'credit',payable,'currency',p.currency));
 if comm>0 then lines:=lines||jsonb_build_object('gl_account_id',unearned_gl,'credit',comm,'currency',p.currency); end if;
 for c in select * from ins_policy_charges where policy_id=p.id and kind='broker_fee' and amount>0 order by id loop
  lines:=lines||jsonb_build_object('gl_account_id',c.income_gl_account_id,'credit',c.amount,'currency',p.currency);
 end loop;
 if vat>0 then lines:=lines||jsonb_build_object('gl_account_id',vat_gl,'credit',vat,'currency',p.currency); end if;
 -- Booked on the inception date (at the inception-date rate).
 je:=post_journal_entry(p.tenant_id,'ins_policy_bind',p.id,p.inception_date,'Bind '||p.policy_no||' (insurer shares and charges)',lines);
 perform fin_create_open_item_fx(p.tenant_id,ar,'ar_control','ins_policy_premium',p.id,p.policy_no,p.inception_date,p.inception_date,total,'Premium and charges: '||p.policy_no,p.currency,je.id);
 for s in select * from ins_policy_insurer_shares where policy_id=p.id order by insurer_id loop
   insurer_account:=ins_ensure_insurer_account(s.insurer_id);
   if s.payable_amount<=0 then raise exception 'INS_FINANCIAL_TOTAL: each insurer payable must be positive'; end if;
   perform fin_create_open_item_fx(p.tenant_id,insurer_account,'insurer_payable','ins_policy_share_insurer',s.id,p.policy_no,p.inception_date,p.inception_date,s.payable_amount,'Insurer share: '||p.policy_no,p.currency,je.id);
   if s.commission_amount>0 then insert into ins_commission_entries(tenant_id,policy_id,insurer_share_id,amount) values(p.tenant_id,p.id,s.id,s.commission_amount); end if;
 end loop;
 perform set_config('ins.via_rpc','on',true);
 update ins_policies set status='active',commission_amount=comm,net_premium_to_insurer=p.gross_premium-comm,bound_at=now(),bound_by=auth.uid(),journal_entry_id=je.id where id=p.id returning * into p;
 if p.renewal_of_id is not null then update ins_policies set status='renewed' where id=p.renewal_of_id and tenant_id=p.tenant_id and status='active'; end if;
 snap:=jsonb_build_object('policy',to_jsonb(p),'shares',(select jsonb_agg(to_jsonb(x) order by insurer_id) from ins_policy_insurer_shares x where policy_id=p.id),
  'charges',coalesce((select jsonb_agg(to_jsonb(x) order by id) from ins_policy_charges x where policy_id=p.id),'[]'::jsonb),
  'open_items',(select jsonb_agg(to_jsonb(i)) from fin_open_items i where tenant_id=p.tenant_id and ((source_type='ins_policy_premium' and source_id=p.id)
    or(source_type='ins_policy_share_insurer' and source_id in(select id from ins_policy_insurer_shares where policy_id=p.id)))));
 insert into ins_policy_financial_snapshots(policy_id,tenant_id,extended,invoice_total,broker_fee_total,vat_total,snapshot,journal_entry_id,bound_by)
 values(p.id,p.tenant_id,true,total,fees,vat,snap,je.id,auth.uid());
 return p;
end $function$;

-- =====================================================================
-- C. Commission transfer between bank accounts
-- =====================================================================
create or replace function public.platform_ins_transfer_before_cancellation_impl(p_from_bank_account_id uuid, p_to_bank_account_id uuid, p_transfer_date date, p_entry_ids uuid[] DEFAULT NULL::uuid[], p_notes text DEFAULT NULL::text)
 returns ins_commission_transfers
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant   uuid := get_my_tenant_id();
  v_from     fin_bank_accounts%rowtype;
  v_to       fin_bank_accounts%rowtype;
  v_ids      uuid[];
  v_total    numeric(18,2);
  v_max_date date;
  v_trust    numeric;
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
  v_other       text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can transfer commission' using errcode = '42501';
  end if;
  if v_tenant is null then
    raise exception 'INS_FORBIDDEN: no company context' using errcode = '42501';
  end if;
  if p_transfer_date is null or p_transfer_date > current_date + 1 then
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
  -- A transfer moves money between accounts that hold the same currency; converting is a
  -- bank payment and a realised result, not a transfer.
  if v_from.currency <> v_to.currency then
    raise exception 'INS_TRANSFER_CURRENCY: a transfer moves money in one currency (% vs %); convert through a bank payment instead',
      v_from.currency, v_to.currency;
  end if;
  v_ccy     := v_from.currency;
  v_foreign := v_ccy <> fin_ledger_currency(v_tenant);

  select array_agg(e.id order by e.id), sum(e.amount), max(e.earned_on)
    into v_ids, v_total, v_max_date
    from ins_commission_entries e
   where e.tenant_id = v_tenant and e.status = 'earned'
     and not exists(select 1 from ins_policy_cancellations c where c.policy_id=e.policy_id and c.status='posted')
     and (p_entry_ids is null or e.id = any (p_entry_ids));
  if v_ids is null then
    raise exception 'INS_TRANSFER_NOTHING: there is no earned commission to transfer';
  end if;
  if p_entry_ids is not null and cardinality(v_ids) <> cardinality(
       (select array_agg(distinct x) from unnest(p_entry_ids) x)) then
    raise exception 'INS_TRANSFER_ENTRIES: every selected entry must be earned and not yet transferred';
  end if;
  -- The trust account holds the commission in the policies' currency; transferring it
  -- through accounts of another currency would not net it.
  select min(p.currency) into v_other
    from ins_commission_entries e join ins_policies p on p.id = e.policy_id
   where e.tenant_id = v_tenant and e.id = any (v_ids) and p.currency is distinct from v_ccy;
  if v_other is not null then
    raise exception 'INS_TRANSFER_CURRENCY: selected commission was earned on % policies; transfer it through % accounts of its own', v_other, v_ccy;
  end if;
  perform 1 from ins_commission_entries where id = any (v_ids) order by id for update;

  if p_transfer_date < v_max_date then
    raise exception 'INS_TRANSFER_DATE: the transfer date cannot be before commission was earned (%)', v_max_date;
  end if;

  -- Client money actually held, in the accounts' currency.
  select coalesce(sum(l.debit - l.credit), 0) into v_trust
    from journal_entry_lines l
   where l.tenant_id = v_tenant and l.gl_account_id = v_from.gl_account_id and l.currency = v_ccy;
  if v_trust < v_total then
    raise exception 'INS_TRANSFER_TRUST_SHORT: client-money account % holds % in the ledger, less than the % to transfer',
      v_from.name, v_trust, v_total;
  end if;

  v_no   := next_doc_number(v_tenant, 'ins_commission_transfer', 'CTR');
  v_desc := 'Commission transfer ' || v_no;

  if not v_foreign then
    v_je := post_journal_entry(v_tenant, 'ins_commission_transfer', v_id, p_transfer_date, v_desc,
      jsonb_build_array(
        jsonb_build_object('gl_account_id', v_to.gl_account_id,   'debit',  v_total, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_from.gl_account_id, 'credit', v_total, 'description', v_desc)));
  else
    -- The trust side is credited at the rate each policy was bound at (naming the bind
    -- entry as the rate source), the operating side debited at the transfer-date rate,
    -- and the difference is the realised result. The trust nets to zero in the currency
    -- and in base.
    v_unearned_gl := get_posting_account(v_tenant, 'unearned_commission');
    v_nr     := round((platform_fx_rate(v_tenant, v_ccy, p_transfer_date)).rate, 8);
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
    v_fx_line := platform_fx_realised_line(v_tenant, v_result, 'Realised exchange result on ' || v_no);
    if v_fx_line is not null then
      v_lines := v_lines || v_fx_line;
    end if;
    v_je := post_journal_entry(v_tenant, 'ins_commission_transfer', v_id, p_transfer_date, v_desc, v_lines);
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
end;
$function$;

-- =====================================================================
-- C2. Voiding a transfer: reverse exactly, currency and rates included
-- =====================================================================
create or replace function public.ins_void_commission_transfer(p_transfer_id uuid, p_reason text, p_void_date date DEFAULT CURRENT_DATE)
 returns ins_commission_transfers
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_tr     ins_commission_transfers%rowtype;
  v_lines  jsonb;
  v_je     journal_entries;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can void a commission transfer' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_TRANSFER_VOID: a reason of at least 5 characters is required';
  end if;

  select * into v_tr from ins_commission_transfers where id = p_transfer_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_TRANSFER_VOID: transfer not found in this company'; end if;
  if v_tr.status <> 'posted' then raise exception 'INS_TRANSFER_VOID: transfer % is already void', v_tr.transfer_no; end if;
  if exists (select 1 from bank_reconciliations r where r.commission_transfer_id = v_tr.id) then
    raise exception 'INS_TRANSFER_RECONCILED: transfer % is matched to a bank statement line; unmatch it in bank reconciliation first', v_tr.transfer_no;
  end if;
  if p_void_date is null or p_void_date < v_tr.transfer_date or p_void_date > current_date + 1 then
    raise exception 'INS_TRANSFER_VOID: the void date must be between the transfer date and today';
  end if;

  -- Swap debit and credit, keeping each line's currency, original rate and rounding flag.
  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id, 'debit', l.credit, 'credit', l.debit,
           'currency', l.currency, 'fx_rate', l.fx_rate, 'is_rounding', l.is_rounding,
           'description', 'Reversal of ' || v_tr.transfer_no))
    into v_lines
    from journal_entry_lines l where l.journal_entry_id = v_tr.journal_entry_id;

  -- Reversal mode: the line guard keeps the original rates, but only rates that the entry
  -- being reversed already used.
  perform set_config('fin.reversal_of', v_tr.journal_entry_id::text, true);
  v_je := post_journal_entry(v_tenant, 'ins_commission_transfer_void', v_tr.id, p_void_date,
    'Void of commission transfer ' || v_tr.transfer_no || ': ' || btrim(p_reason), v_lines);
  perform set_config('fin.reversal_of', '', true);

  insert into ins_commission_events (tenant_id, entry_id, event, amount, journal_entry_id, transfer_id)
  select v_tenant, e.id, 'transfer_voided', e.amount, v_je.id, v_tr.id
    from ins_commission_entries e where e.transfer_id = v_tr.id and e.tenant_id = v_tenant;

  update ins_commission_entries
     set status = 'earned', transfer_id = null, updated_at = now()
   where transfer_id = v_tr.id and tenant_id = v_tenant;

  update ins_commission_transfers
     set status = 'void', void_journal_entry_id = v_je.id, voided_at = now(),
         voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = v_tr.id
  returning * into v_tr;

  return v_tr;
end;
$function$;

-- =====================================================================
-- D. Commission recognition on paying the insurer (and its reversal)
-- =====================================================================
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
    join fin_open_items i  on i.id = al.open_item_id and i.source_type in ('ins_policy_insurer','ins_policy_share_insurer')
    join ins_commission_entries e on ((e.insurer_share_id=i.source_id and i.source_type='ins_policy_share_insurer') or (e.policy_id=i.source_id and e.insurer_share_id is null and i.source_type='ins_policy_insurer')) and e.tenant_id=i.tenant_id
    join ins_policies p on p.id = e.policy_id
    where al.settlement_id = new.id
      and e.status = 'deferred'
      and ins_item_paid_amount(i.id) >= i.amount
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
    select e.id as entry_id, e.amount, e.status as entry_status, p.policy_no, i.currency as item_currency
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

    v_unearned := get_posting_account(new.tenant_id, 'unearned_commission');
    v_income   := get_posting_account(new.tenant_id, 'commission_income');
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: reversing commission on % needs the unearned_commission and commission_income posting rules', r.policy_no;
    end if;

    v_ev := gen_random_uuid();
    if r.item_currency is distinct from fin_ledger_currency(new.tenant_id) then
      -- Reverse the recognition journal exactly: its lines carry the currency and the
      -- booked rate, and reversal mode keeps them, so the recognition negates to zero.
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
       set status = 'deferred', earned_on = null, updated_at = now()
     where id = r.entry_id;
  end loop;

  return new;
end;
$function$;

-- =====================================================================
-- E. Claim recognition accrues in the policy's currency
-- =====================================================================
create or replace function public.ins_recognise_claim_receivable(p_claim_id uuid, p_insurer_confirmation text)
 returns ins_claims
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_insurer uuid;
  v_client  uuid;
  v_ccy     text;
  v_recv_gl uuid;
  v_pay_gl  uuid;
  v_ins_acc uuid;
  v_cli_acc uuid;
  v_desc    text;
  v_je      journal_entries%rowtype;
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

  select p.insurer_id, p.client_id, p.currency into v_insurer, v_client, v_ccy from ins_policies p where p.id = v_claim.policy_id;
  v_recv_gl := get_posting_account(v_tenant, 'insurer_claim_receivable');
  v_pay_gl  := get_posting_account(v_tenant, 'client_claim_payable');
  if v_recv_gl is null or v_pay_gl is null then
    raise exception 'INS_POSTING_RULE_MISSING: this insurer pays claims through the brokerage, so the chart of accounts needs insurer_claim_receivable and client_claim_payable';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  v_ins_acc := ins_ensure_insurer_account(v_insurer);
  v_cli_acc := ins_ensure_client_account(v_client);
  v_desc := 'Claim ' || v_claim.claim_no || ' recognised: insurer confirmed payment through the brokerage';
  v_je := post_journal_entry(v_tenant, 'ins_claim_accrual', v_claim.id, current_date, v_desc, jsonb_build_array(
    jsonb_build_object('gl_account_id', v_recv_gl, 'debit',  v_claim.approved_amount, 'currency', v_ccy, 'description', v_desc),
    jsonb_build_object('gl_account_id', v_pay_gl,  'credit', v_claim.approved_amount, 'currency', v_ccy, 'description', v_desc)));
  -- The claim items hold the rate the accrual was booked at.
  perform fin_create_open_item_fx(v_tenant, v_ins_acc, 'insurer_claim_receivable', 'ins_claim_insurer', v_claim.id,
    v_claim.claim_no, current_date, current_date, v_claim.approved_amount, 'Claim funds due from the insurer', v_ccy, v_je.id);
  perform fin_create_open_item_fx(v_tenant, v_cli_acc, 'client_claim_payable', 'ins_claim_client', v_claim.id,
    v_claim.claim_no, current_date, current_date, v_claim.approved_amount, 'Claim proceeds due to the client', v_ccy, v_je.id);

  update ins_claims set recognised_at = now(), recognised_by = auth.uid()
   where id = v_claim.id returning * into v_claim;
  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_claim.id, 'approved', 'approved', 'Receivable recognised. Insurer confirmation: ' || btrim(p_insurer_confirmation));
  return v_claim;
end;
$function$;

-- =====================================================================
-- F. The cancellation pipeline stays functional-currency for now (3d-3)
-- =====================================================================
create or replace function public.ins_cancellation_currency_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_ccy text;
begin
  select currency into v_ccy from public.ins_policies where id = coalesce(new.policy_id, old.policy_id);
  if v_ccy is distinct from fin_ledger_currency(coalesce(new.tenant_id, old.tenant_id)) then
    raise exception 'INS_CANCELLATION_CURRENCY: cancelling a % policy is not supported yet; the cancellation pipeline posts in the ledger currency only', v_ccy;
  end if;
  return coalesce(new, old);
end;
$function$;
revoke all on function public.ins_cancellation_currency_guard() from public, anon, authenticated;

drop trigger if exists trg_ins_cancellation_currency on public.ins_policy_cancellations;
create trigger trg_ins_cancellation_currency
  before insert or update
  on public.ins_policy_cancellations
  for each row execute function public.ins_cancellation_currency_guard();

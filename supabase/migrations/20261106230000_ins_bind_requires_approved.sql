-- =====================================================================
-- Insurance brokerage: bind requires an APPROVED policy.
-- Fixes the contradiction left by 20261106180000: the ins_policies_guard
-- trigger only allows approved -> active, but both bind implementations
-- still demanded status = 'draft', so an approved policy could never be
-- bound (INS_NOT_DRAFT) and a draft was rejected by the guard
-- (INS_NOT_APPROVED). Both impls are re-created here with the approved
-- check; the ins_bind_policy wrapper is unchanged.
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
 if p.status<>'approved' then raise exception 'INS_NOT_APPROVED: policy is % (submit for approval first)', p.status; end if;
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


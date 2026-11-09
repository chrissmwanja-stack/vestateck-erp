-- Cancellation phase 1: authoritative, read-only calculation/review.
-- This migration does NOT cancel a policy, post accounting, approve an
-- exception, authorize a refund, or weaken any existing reversal/cash guard.
-- Actual cancellation approval must recalculate under locks in a later phase.
-- Agreed rules:
-- * Insurer contractual methods/minimum retention/non-refundability take priority.
-- * Pro-rata is a fallback only where the contract permits it.
-- * Commission uses each insurer's immutable bound rate, never a blended rate.
-- * Charge refund/retention and its legal/contractual basis are recipient-specific.
-- * Existing claims block v1; no claim status is silently treated as harmless.
-- * A calculation, cancellation approval and cash approval are distinct acts.
-- Remaining release gates (NOT implemented by this migration):
-- 1. Durable proposals, independent Finance review, idempotent atomic approval.
-- 2. Current-date credit documents/journals: unpaid receivable reductions,
--    client refund liabilities, insurer payable reductions/recovery receivables,
--    commission adjustments and broker-fee/VAT credits, all linked to the case.
-- 3. Policy-specific available-funds checks, actual insurer recovery receipts,
--    Finance maker/different checker payments and third-person reconciliation.
-- 4. Commission already transferred: track/recover the clawback, never pretend
--    that an income reversal has returned money to the client-money bank.
-- 5. UI/audit/reporting and real two-session approval/refund/void races.
-- Original bind snapshots and posted cash/commission histories must stay intact.

create function public.platform_ins_cancellation_money(p_value text) returns numeric
language plpgsql immutable set search_path=public,pg_temp as $$
begin
 if p_value is null or p_value !~ '^\d{1,16}(\.\d{1,2})?$' then
  raise exception 'INS_CANCELLATION_INPUT: non-negative decimal money with at most two decimals required';
 end if;
 return p_value::numeric;
end $$;
revoke all on function public.platform_ins_cancellation_money(text) from public,anon,authenticated;

create function public.platform_ins_cancellation_percentage(p_value text,p_allow_100 boolean default true) returns numeric
language plpgsql immutable set search_path=public,pg_temp as $$
declare n numeric;
begin
 if p_value is null or p_value !~ '^\d{1,3}(\.\d{1,4})?$' then raise exception 'INS_CANCELLATION_INPUT: percentage requires at most four decimals'; end if;
 n:=p_value::numeric;
 if n>100 or (not p_allow_100 and n=100) then raise exception 'INS_CANCELLATION_INPUT: percentage out of range'; end if;
 return n;
end $$;
revoke all on function public.platform_ins_cancellation_percentage(text,boolean) from public,anon,authenticated;

-- Exact positive half-up ratio rounding, with no numeric-division double rounding.
create function public.platform_ins_cancellation_round_ratio(p_numerator numeric,p_denominator numeric) returns numeric
language plpgsql immutable set search_path=public,pg_temp as $$
begin
 if p_numerator is null or p_denominator is null or p_numerator<0 or p_denominator<=0 then
  raise exception 'INS_CANCELLATION_INPUT: invalid non-negative ratio'; end if;
 return div(p_numerator*200+p_denominator,p_denominator*2)*.01;
end $$;
revoke all on function public.platform_ins_cancellation_round_ratio(numeric,numeric) from public,anon,authenticated;

create function public.platform_ins_calculate_insurer_cancellation(
 p_allocation jsonb,p_terms jsonb,p_inception date,p_expiry date,p_effective date
) returns jsonb language plpgsql immutable set search_path=public,pg_temp as $$
declare premium numeric; original_comm numeric; rate numeric; minimum numeric;
 retained numeric; returned numeric; clawback numeric; total_days integer; used_days integer;
 band jsonb; band_day integer; band_rate numeric; selected_rate numeric; last_day integer:=-1; last_rate numeric:=-1;
 method text:=p_terms->>'method'; ref text:=btrim(p_terms->>'contract_reference');
begin
 if jsonb_typeof(p_allocation) is distinct from 'object' or jsonb_typeof(p_terms) is distinct from 'object' then
  raise exception 'INS_CANCELLATION_INPUT: insurer allocation and contractual terms required'; end if;
 premium:=platform_ins_cancellation_money(p_allocation->>'premium_amount');
 original_comm:=platform_ins_cancellation_money(p_allocation->>'commission_amount');
 rate:=platform_ins_cancellation_percentage(p_allocation->>'commission_rate_pct',false);
 if nullif(p_allocation->>'insurer_id','') is null or premium<=0 or original_comm<>platform_ins_cancellation_round_ratio(premium*rate,100) then
  raise exception 'INS_CANCELLATION_INPUT: original bound premium and commission do not reconcile'; end if;
 if ref is null or length(ref)<5 then raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: record insurer-specific contract evidence'; end if;
 if p_inception is null or p_expiry is null or p_effective is null or p_expiry<p_inception or p_effective<p_inception or p_effective>p_expiry+1 then
  raise exception 'INS_CANCELLATION_INPUT: effective date is outside the inclusive cover period'; end if;
 total_days:=p_expiry-p_inception+1; used_days:=p_effective-p_inception;
 minimum:=platform_ins_cancellation_money(coalesce(p_terms->>'minimum_retained_premium','0'));
 if minimum>premium then raise exception 'INS_CANCELLATION_INPUT: minimum retained exceeds original premium'; end if;
 case method
 when 'pro_rata' then
  if jsonb_typeof(p_terms->'short_period_bands')='array' and p_terms->'short_period_bands'<>'[]'::jsonb then
   raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: specific short-period terms take priority over pro-rata'; end if;
  if p_terms->'pro_rata_permitted' is distinct from 'true'::jsonb then
   raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: contract must permit pro-rata'; end if;
  retained:=premium-platform_ins_cancellation_round_ratio(premium*(total_days-used_days),total_days);
 when 'short_period' then
  if jsonb_typeof(p_terms->'short_period_bands') is distinct from 'array' then
   raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: complete short-period schedule required'; end if;
  if jsonb_array_length(p_terms->'short_period_bands') not between 1 and 100 then
   raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: complete short-period schedule required'; end if;
  for band in select value from jsonb_array_elements(p_terms->'short_period_bands') loop
   if coalesce(band->>'through_day','') !~ '^\d+$' then raise exception 'INS_CANCELLATION_INPUT: short-period days must be non-negative integers'; end if;
   band_day:=(band->>'through_day')::integer;
   band_rate:=platform_ins_cancellation_percentage(band->>'retained_pct');
   if band_day<=last_day or band_rate<last_rate then raise exception 'INS_CANCELLATION_INPUT: short-period days must increase and rates cannot decrease'; end if;
   if selected_rate is null and used_days<=band_day then selected_rate:=band_rate; end if;
   last_day:=band_day; last_rate:=band_rate;
  end loop;
  if last_day<total_days or last_rate<>100 then raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: final band must cover full term at 100 percent retention'; end if;
  retained:=platform_ins_cancellation_round_ratio(premium*selected_rate,100);
 when 'non_refundable' then retained:=premium;
 when 'manual_review' then
  if p_terms->>'manual_return_premium' is null then raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: Finance must determine the actual return premium'; end if;
  returned:=platform_ins_cancellation_money(p_terms->>'manual_return_premium');
  if returned>premium then raise exception 'INS_CANCELLATION_INPUT: return exceeds original premium'; end if;
  retained:=premium-returned;
 else raise exception 'INS_CANCELLATION_INPUT: unknown cancellation method';
 end case;
 retained:=greatest(retained,minimum);
 if used_days=total_days then retained:=premium; end if;
 returned:=premium-retained;
 clawback:=case when returned=premium then original_comm else platform_ins_cancellation_round_ratio(returned*rate,100) end;
 if clawback>original_comm or clawback>returned then raise exception 'INS_CANCELLATION_INPUT: commission clawback does not reconcile'; end if;
 return jsonb_build_object('insurer_id',p_allocation->>'insurer_id','method',method,'contract_reference',ref,
  'original_premium',premium::text,'retained_premium',retained::text,'return_premium',returned::text,
  'original_commission',original_comm::text,'commission_clawback',clawback::text,'net_insurer_credit',(returned-clawback)::text,
  'requires_finance_exception',method='manual_review');
end $$;
revoke all on function public.platform_ins_calculate_insurer_cancellation(jsonb,jsonb,date,date,date) from public,anon,authenticated;

-- Proportional allocation ESTIMATE only; contractual pass-through decisions
-- in the authorized preview require explicit amounts per original recipient.
create function public.platform_ins_allocate_cancellation_refund(p_original jsonb,p_refund text) returns jsonb
language plpgsql immutable set search_path=public,pg_temp as $$
declare amount numeric:=platform_ins_cancellation_money(p_refund); total numeric; result jsonb;
begin
 if jsonb_typeof(p_original) is distinct from 'array' then raise exception 'INS_CANCELLATION_INPUT: original charge recipients required'; end if;
 if jsonb_array_length(p_original)=0 or exists(select 1 from jsonb_array_elements(p_original) x where nullif(x->>'insurer_id','') is null)
  or (select count(*)<>count(distinct x->>'insurer_id') from jsonb_array_elements(p_original) x) then
  raise exception 'INS_CANCELLATION_INPUT: unique original charge recipients required'; end if;
 select sum(platform_ins_cancellation_money(x->>'amount')) into total from jsonb_array_elements(p_original) x;
 if amount>total then raise exception 'INS_CANCELLATION_INPUT: charge refund exceeds original charge'; end if;
 with bases as (
  select x->>'insurer_id' as insurer_id,
   case when total=0 then 0 else div(amount*100*platform_ins_cancellation_money(x->>'amount')*100,total*100)*.01 end as base,
   case when total=0 then 0 else mod(amount*100*platform_ins_cancellation_money(x->>'amount')*100,total*100) end as fraction,
   ord from jsonb_array_elements(p_original) with ordinality t(x,ord)
 ), ranked as(select *,row_number() over(order by fraction desc,insurer_id collate "C") as rank,
   round((amount-sum(base) over())*100) as cents from bases)
 select jsonb_agg(jsonb_build_object('insurer_id',insurer_id,'amount',(base+case when rank<=cents then .01 else 0 end)::text) order by ord) into result from ranked;
 return result;
end $$;
revoke all on function public.platform_ins_allocate_cancellation_refund(jsonb,text) from public,anon,authenticated;

create function public.ins_preview_policy_cancellation(p_policy_id uuid,p_effective_date date,p_insurer_terms jsonb,p_charge_refunds jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare p ins_policies%rowtype; snap ins_policy_financial_snapshots%rowtype; shares jsonb; charges jsonb;
 allocation jsonb; term jsonb; charge jsonb; rule jsonb; calc jsonb; insurers jsonb:='[]'; charge_results jsonb:='[]'; pass_rows jsonb:='[]';
 original_parts jsonb; parts jsonb; part jsonb; decision jsonb; recipient_refund numeric; recipient_total numeric; final_insurers jsonb:='[]';
 refund numeric; original_amount numeric; original_vat numeric; vat_refund numeric; premium_return numeric:=0; total_credit numeric:=0;
 invoice numeric; unpaid numeric; pass_refund numeric; requires_exception boolean:=false; item_count integer;
begin
 if auth.uid() is null or effective_user_id() is distinct from auth.uid()
  or not (can_manage_insurance() or is_finance_team_member('finance')) then
  raise exception 'INS_FORBIDDEN: Insurance manager or Finance acting as themselves required' using errcode='42501'; end if;
 select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 if p.status not in('active','renewed') then raise exception 'INS_CANCELLATION_STATE: bound policy required'; end if;
 if exists(select 1 from ins_claims where policy_id=p.id and tenant_id=p.tenant_id) then
  raise exception 'INS_CANCELLATION_CLAIM: policies with existing claims are not supported in v1'; end if;
 if p_effective_date is null or p_effective_date>current_date then raise exception 'INS_CANCELLATION_INPUT: a non-future effective cancellation date is required'; end if;
 if jsonb_typeof(p_insurer_terms) is distinct from 'array' or jsonb_typeof(p_charge_refunds) is distinct from 'array' then
  raise exception 'INS_CANCELLATION_INPUT: insurer terms and charge decisions must be arrays'; end if;
 if jsonb_array_length(p_insurer_terms)>30 or jsonb_array_length(p_charge_refunds)>100 then raise exception 'INS_CANCELLATION_INPUT: too many input lines'; end if;
 select * into snap from ins_policy_financial_snapshots where policy_id=p.id and tenant_id=p.tenant_id;
 -- Financial data comes only from immutable bind-time records, never from
 -- client-supplied premiums, shares, commission rates, recipients or VAT rates.
 shares:=snap.snapshot->'shares'; charges:=coalesce(snap.snapshot->'charges','[]'::jsonb);
 if shares is null or shares='[]'::jsonb then
  shares:=jsonb_build_array(jsonb_build_object('insurer_id',p.insurer_id,'premium_amount',p.gross_premium,
   'commission_amount',p.commission_amount,'commission_rate_pct',p.commission_rate_pct,'share_pct',100));
 end if;
 invoice:=coalesce(snap.invoice_total,p.gross_premium);
 if jsonb_array_length(p_insurer_terms)<>jsonb_array_length(shares)
  or (select count(*)<>count(distinct x->>'insurer_id') from jsonb_array_elements(p_insurer_terms) x) then
  raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: provide one set of terms for every original insurer'; end if;
 for allocation in select value from jsonb_array_elements(shares) loop
  select x->'terms' into term from jsonb_array_elements(p_insurer_terms) x where x->>'insurer_id'=allocation->>'insurer_id';
  if term is null then raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: missing original insurer terms'; end if;
  calc:=platform_ins_calculate_insurer_cancellation(allocation,term,p.inception_date,p.expiry_date,p_effective_date);
  insurers:=insurers||jsonb_build_array(calc);
  premium_return:=premium_return+(calc->>'return_premium')::numeric;
  requires_exception:=requires_exception or (calc->>'requires_finance_exception')::boolean;
 end loop;
 if jsonb_array_length(p_charge_refunds)<>jsonb_array_length(charges)
  or (select count(*)<>count(distinct x->>'charge_id') from jsonb_array_elements(p_charge_refunds) x) then
  raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: decide every original charge, including zero-valued lines'; end if;
 total_credit:=premium_return;
 for charge in select value from jsonb_array_elements(charges) loop
  select x into rule from jsonb_array_elements(p_charge_refunds) x where x->>'charge_id'=charge->>'id';
  if rule is null or rule->'legal_basis_confirmed' is distinct from 'true'::jsonb or length(btrim(coalesce(rule->>'basis','')))<5 then
   raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: confirm the contractual/legal basis for every refundable or retained charge'; end if;
  original_amount:=platform_ins_cancellation_money(charge->>'amount');
  refund:=platform_ins_cancellation_money(rule->>'refund_amount');
  if refund>original_amount then raise exception 'INS_CANCELLATION_INPUT: charge refund exceeds its original amount'; end if;
  original_vat:=coalesce((charge->>'vat_amount')::numeric,0); vat_refund:=0;
  if charge->>'kind'='broker_fee' then
   if original_amount=0 and original_vat<>0 then raise exception 'INS_CANCELLATION_HISTORY: VAT without broker-fee base'; end if;
   vat_refund:=case when original_amount=0 then 0 when refund=original_amount then original_vat else platform_ins_cancellation_round_ratio(original_vat*refund,original_amount) end;
  else
   if charge->>'recipient_mode'='one_insurer' then
    original_parts:=jsonb_build_array(jsonb_build_object('insurer_id',charge->>'recipient_insurer_id','amount',original_amount::text));
   else
    -- Reconstruct the exact original Hamilton allocation from immutable shares.
    with bases as(select x->>'insurer_id' as insurer_id,trunc(original_amount*(x->>'share_pct')::numeric/100,2) as base,
      original_amount*(x->>'share_pct')::numeric/100-trunc(original_amount*(x->>'share_pct')::numeric/100,2) as fraction from jsonb_array_elements(shares) x),
    ranked as(select *,row_number() over(order by fraction desc,insurer_id collate "C") as rank,round((original_amount-sum(base) over())*100) as cents from bases)
    select jsonb_agg(jsonb_build_object('insurer_id',insurer_id,'amount',(base+case when rank<=cents then .01 else 0 end)::text)) into original_parts from ranked;
   end if;
   if jsonb_typeof(rule->'insurer_refunds') is distinct from 'array' then
    raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: each pass-through recipient needs its own explicit refund decision'; end if;
   if jsonb_array_length(rule->'insurer_refunds')<>jsonb_array_length(original_parts)
     or (select count(*)<>count(distinct x->>'insurer_id') from jsonb_array_elements(rule->'insurer_refunds') x) then
    raise exception 'INS_CANCELLATION_INPUT: exactly one charge decision per original recipient required'; end if;
   recipient_total:=0;
   for part in select value from jsonb_array_elements(original_parts) loop
    select x into decision from jsonb_array_elements(rule->'insurer_refunds') x where x->>'insurer_id'=part->>'insurer_id';
    if decision is null or length(btrim(coalesce(decision->>'basis','')))<5 then
     raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: recipient-specific charge refund/retention basis required'; end if;
    recipient_refund:=platform_ins_cancellation_money(decision->>'refund_amount');
    if recipient_refund>(part->>'amount')::numeric then raise exception 'INS_CANCELLATION_INPUT: refund exceeds recipient original charge allocation'; end if;
    recipient_total:=recipient_total+recipient_refund;
    pass_rows:=pass_rows||jsonb_build_array(jsonb_build_object('insurer_id',part->>'insurer_id','charge_id',charge->>'id',
     'amount',recipient_refund::text,'original_amount',part->>'amount','retained_amount',((part->>'amount')::numeric-recipient_refund)::text,'basis',decision->>'basis'));
   end loop;
   if recipient_total<>refund then raise exception 'INS_CANCELLATION_INPUT: recipient refunds must equal the charge refund'; end if;
  end if;
  total_credit:=total_credit+refund+vat_refund;
  charge_results:=charge_results||jsonb_build_array(jsonb_build_object('charge_id',charge->>'id','kind',charge->>'kind',
   'refund_base',refund::text,'retained_base',(original_amount-refund)::text,'refund_vat',vat_refund::text,'retained_vat',(original_vat-vat_refund)::text,
   'basis',btrim(rule->>'basis'),'recipient_mode',charge->>'recipient_mode','recipient_insurer_id',charge->>'recipient_insurer_id',
   'vat_mode',charge->>'vat_mode','income_gl_account_id',charge->>'income_gl_account_id'));
 end loop;
 for calc in select value from jsonb_array_elements(insurers) loop
  select coalesce(sum((x->>'amount')::numeric),0) into pass_refund from jsonb_array_elements(pass_rows) x where x->>'insurer_id'=calc->>'insurer_id';
  final_insurers:=final_insurers||jsonb_build_array(calc||jsonb_build_object('pass_through_refund',pass_refund::text,
   'total_insurer_credit',((calc->>'net_insurer_credit')::numeric+pass_refund)::text));
 end loop;
 select count(*),sum(outstanding_amount) into item_count,unpaid from fin_open_item_balances where tenant_id=p.tenant_id and source_id=p.id and source_type='ins_policy_premium';
 if item_count<>1 or unpaid<0 or unpaid>invoice or total_credit>invoice then raise exception 'INS_CANCELLATION_HISTORY: policy receivable does not reconcile'; end if;
 if exists(select 1 from fin_credit_applications a join fin_credit_notes n on n.id=a.credit_note_id
   join fin_open_items i on i.id=a.open_item_id where i.tenant_id=p.tenant_id and i.source_type='ins_policy_premium' and i.source_id=p.id and n.status='posted') then
  raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: existing policy credits require Finance review'; end if;
 return jsonb_build_object('stage','calculation_only','approval_status','not_approved','payment_authorized',false,
  'policy_id',p.id,'currency',p.currency,'effective_date',p_effective_date,'generated_at',now(),
  'cover_day_convention','inclusive cover dates; cancellation day is not earned cover',
  'insurers',final_insurers,'charges',charge_results,'pass_through_allocations',pass_rows,
  'invoice_credit',total_credit::text,'receivable_credit',least(total_credit,unpaid)::text,'client_refund_due',greatest(total_credit-unpaid,0)::text,
  'requires_finance_review',true,'requires_finance_exception',requires_exception,
  'funding_status','not_checked','notice','Calculation only. Cancellation approval and separately approved, funded cash payment are still required.');
end $$;
revoke all on function public.ins_preview_policy_cancellation(uuid,date,jsonb,jsonb) from public,anon;
grant execute on function public.ins_preview_policy_cancellation(uuid,date,jsonb,jsonb) to authenticated;

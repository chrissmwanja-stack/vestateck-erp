-- =====================================================================
-- Wire ins.cancellation_treatment into the cancellation path.
-- Per-agreement terms (p_insurer_terms.method) still take priority;
-- without one, the approved company setting supplies the default method.
-- =====================================================================

drop function if exists public.ins_submit_policy_cancellation(uuid,date,jsonb,jsonb,text,uuid);
create or replace function public.ins_submit_policy_cancellation(p_policy_id uuid,p_effective_date date,p_insurer_terms jsonb,p_charge_refunds jsonb,p_reason text,p_request_key uuid)
returns public.ins_policy_cancellations language plpgsql security definer set search_path=public,pg_temp as $$
declare c ins_policy_cancellations%rowtype; quote jsonb; v_method text;
begin
 -- Company-configured default cancellation treatment: an explicit method in
 -- the insurer's terms (per-agreement override) always wins; otherwise the
 -- approved ins.cancellation_treatment setting supplies the method.
 v_method := nullif(btrim(coalesce(p_insurer_terms->>'method','')),'');
 if v_method is null then
   v_method := case public.acct_get_setting('ins.cancellation_treatment', p_effective_date)
     when 'pro_rata_refund' then 'pro_rata'
     when 'short_rate_refund' then 'short_period'
     when 'no_refund' then 'non_refundable'
     else 'manual_review' end;
   p_insurer_terms := jsonb_set(coalesce(p_insurer_terms,'{}'::jsonb),'{"method"}',to_jsonb(v_method));
 end if;
 if auth.uid() is null or effective_user_id() is distinct from auth.uid() or not(can_manage_insurance() or is_finance_team_member('finance')) then
  raise exception 'INS_FORBIDDEN: Insurance manager or Finance acting as themselves required' using errcode='42501'; end if;
 if p_request_key is null or p_reason is null or length(btrim(p_reason)) not between 5 and 2000 then raise exception 'INS_CANCELLATION_INPUT: request key and reason required'; end if;
 perform id from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 select * into c from ins_policy_cancellations where tenant_id=get_my_tenant_id() and request_key=p_request_key;
 if found then
  if c.proposed_by<>auth.uid() or c.policy_id is distinct from p_policy_id or c.effective_date is distinct from p_effective_date or c.insurer_terms is distinct from p_insurer_terms
   or c.charge_refunds is distinct from p_charge_refunds or c.reason is distinct from btrim(p_reason) then raise exception 'INS_CANCELLATION_RETRY_CONFLICT: different payload'; end if;
  return c;
 end if;
 quote:=ins_preview_policy_cancellation(p_policy_id,p_effective_date,p_insurer_terms,p_charge_refunds);
 if exists(select 1 from ins_policy_cancellations where policy_id=p_policy_id and status in('proposed','prepared','posting','posted')) then raise exception 'INS_CANCELLATION_EXISTS: a live proposal or posted cancellation already exists'; end if;
 insert into ins_policy_cancellations(tenant_id,policy_id,request_key,reason,effective_date,insurer_terms,charge_refunds,proposed_by,calculation)
 values(get_my_tenant_id(),p_policy_id,p_request_key,btrim(p_reason),p_effective_date,p_insurer_terms,p_charge_refunds,auth.uid(),quote) returning * into c;
 insert into ins_cancellation_events(tenant_id,cancellation_id,event,actor_id) values(c.tenant_id,c.id,'proposed',auth.uid());
 return c;
end $$;
revoke all on function public.ins_submit_policy_cancellation(uuid,date,jsonb,jsonb,text,uuid) from public,anon;
revoke all on function public.ins_submit_policy_cancellation(uuid,date,jsonb,jsonb,text,uuid) from public,anon;
grant execute on function public.ins_submit_policy_cancellation(uuid,date,jsonb,jsonb,text,uuid) to authenticated;

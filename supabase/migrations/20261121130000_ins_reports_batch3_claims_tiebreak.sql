-- =====================================================================
-- Insurance reports, batch 3 fix: latest status and reserve when several
-- rows share one timestamp
-- =====================================================================
--
-- ins_report_claims_register picked the latest claim event and the latest
-- reserve revision with "order by <timestamp> desc, id desc". Both ids are
-- gen_random_uuid() and both timestamps default to now(), which is fixed for
-- a whole transaction. Rows written in one transaction (an import, a bulk
-- action, or a test fixture) therefore tied on the timestamp and the tie was
-- broken at random, so the register could show the initial reserve instead of
-- the revision, or an earlier status instead of the latest.
--
-- Tie-break: among rows with the same timestamp, the latest row is the one
-- that no other tied row follows. For events, a successor is a tied event whose
-- from_status equals this event's to_status. For reserves, a successor is a
-- tied revision whose previous_amount equals this row's new_amount. The id
-- remains as the final tie-break only.
--
-- Limit: if a claim returns to a status it already had inside the same
-- timestamp, the chain is ambiguous and the id decides.
--
-- Only the register changes (create or replace, same signature, same
-- grants). Ageing reads the register, so it is fixed with it. The earlier
-- migration is left as it was, per MIGRATION_POLICY.md.
-- =====================================================================

create or replace function public.ins_report_claims_register(
  p_as_of date default current_date,
  p_scope text default 'open'
)
returns table (
  claim_id            uuid,
  claim_no            text,
  insurer_claim_ref   text,
  policy_id           uuid,
  policy_no           text,
  client_id           uuid,
  client_name         text,
  insurer_id          uuid,
  insurer_name        text,
  product_line_id     uuid,
  product_line_name   text,
  currency            text,
  loss_date           date,
  notified_date       date,
  status_as_at        text,
  is_open             boolean,
  reserve_as_at       numeric,
  approved_amount     numeric,
  paid_as_at          numeric,
  outstanding_amount  numeric,
  age_days            integer,
  days_since_activity integer,
  age_bucket          text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if auth.uid() is null or not public.can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;
  if p_as_of is null then
    raise exception 'INS_REPORT_INPUT: an as-at date is required';
  end if;
  if p_scope is null or p_scope not in ('open', 'all') then
    raise exception 'INS_REPORT_INPUT: scope must be open or all';
  end if;

  return query
  with st as (
    select c.id as cid,
           (select e.to_status
              from public.ins_claim_events e
             where e.claim_id = c.id and e.tenant_id = v_tenant
               and e.created_at::date <= p_as_of
             order by e.created_at desc,
                      exists (select 1 from public.ins_claim_events n
                               where n.claim_id = e.claim_id and n.tenant_id = v_tenant
                                 and n.created_at = e.created_at
                                 and n.from_status = e.to_status and n.id <> e.id),
                      e.id desc
             limit 1) as status_at,
           (select e.created_at::date
              from public.ins_claim_events e
             where e.claim_id = c.id and e.tenant_id = v_tenant
               and e.created_at::date <= p_as_of
             order by e.created_at desc,
                      exists (select 1 from public.ins_claim_events n
                               where n.claim_id = e.claim_id and n.tenant_id = v_tenant
                                 and n.created_at = e.created_at
                                 and n.from_status = e.to_status and n.id <> e.id),
                      e.id desc
             limit 1) as last_activity
      from public.ins_claims c
     where c.tenant_id = v_tenant
       and c.notified_date <= p_as_of
  ),
  calc as (
    select c.*,
           coalesce(st.status_at, 'notified') as status_at,
           coalesce(st.last_activity, c.notified_date) as last_activity,
           coalesce(
             (select h.new_amount
                from public.ins_claim_reserve_history h
               where h.claim_id = c.id and h.tenant_id = v_tenant
                 and h.revised_at::date <= p_as_of
               order by h.revised_at desc,
                        exists (select 1 from public.ins_claim_reserve_history n
                                 where n.claim_id = h.claim_id and n.tenant_id = v_tenant
                                   and n.revised_at = h.revised_at
                                   and n.previous_amount = h.new_amount and n.id <> h.id),
                        h.id desc
               limit 1),
             (select h.new_amount
                from public.ins_claim_reserve_history h
               where h.claim_id = c.id and h.tenant_id = v_tenant and h.kind = 'initial'
               limit 1),
             c.reserve_amount) as reserve_at,
           coalesce((select sum(p.amount)
                       from public.ins_claim_payments p
                      where p.claim_id = c.id and p.tenant_id = v_tenant
                        and p.kind in ('insurer_direct', 'client_payout')
                        and p.payment_date <= p_as_of
                        and (p.status = 'posted'
                             or (p.status = 'void' and p.voided_at::date > p_as_of))), 0) as paid_at
      from public.ins_claims c
      join st on st.cid = c.id
  ),
  fin as (
    select k.*,
           (k.status_at in ('notified', 'assessing', 'approved')) as open_flag,
           case
             when k.status_at = 'approved'
               then greatest(coalesce(k.approved_amount, 0) - k.paid_at, 0)
             when k.status_at in ('notified', 'assessing') then k.reserve_at
             else 0
           end as outstanding_at
      from calc k
  )
  select f.id, f.claim_no, f.insurer_claim_ref,
         p.id, p.policy_no, p.client_id, bd.name,
         p.insurer_id, ins.name, p.product_line_id, pl.name,
         p.currency,
         f.loss_date, f.notified_date, f.status_at, f.open_flag,
         f.reserve_at,
         case when f.status_at in ('approved', 'settled') then f.approved_amount else null end,
         f.paid_at, f.outstanding_at,
         (p_as_of - f.notified_date)::integer,
         (p_as_of - f.last_activity)::integer,
         case
           when not f.open_flag then 'closed'
           when p_as_of - f.notified_date <= 30  then '0-30'
           when p_as_of - f.notified_date <= 60  then '31-60'
           when p_as_of - f.notified_date <= 90  then '61-90'
           when p_as_of - f.notified_date <= 180 then '91-180'
           else '180+'
         end
    from fin f
    join public.ins_policies p on p.id = f.policy_id and p.tenant_id = v_tenant
    left join public.ins_clients cl on cl.id = p.client_id
    left join public.bd_clients bd on bd.id = cl.client_id
    left join public.ins_insurers ins on ins.id = p.insurer_id
    left join public.ins_product_lines pl on pl.id = p.product_line_id
   where (p_scope = 'all' or f.open_flag)
   order by p.currency, f.notified_date, f.claim_no;
end;
$$;

revoke all on function public.ins_report_claims_register(date, text) from public, anon;
grant execute on function public.ins_report_claims_register(date, text) to authenticated;

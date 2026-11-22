-- =====================================================================
-- Claim approval history -- ins_claim_approval_history
-- =====================================================================
-- The approval decision is the one financial figure a claim keeps that was
-- not kept as history: ins_claims.approved_amount was set by ins_transition_claim
-- and overwritten (or cleared, on un-approval) in place, so a report for a past
-- date could only show the claim's current approved amount. DR-41 recorded the
-- limitation; the owner decided on 2026-11-22 that approval decisions should be
-- kept as history and that the claims register should show the approved amount
-- as it stood on the as-at date (see docs/insurance-brokerage/CLAIM_APPROVAL_REVISION_DESIGN.md).
--
-- This migration:
--
--   1. Creates ins_claim_approval_history -- one row per approval decision and
--      one per withdrawal of an approval. Immutable, RPC-only, tenant-scoped.
--      Shape mirrors ins_claim_reserve_history (initial / revision) plus a
--      'cleared' kind for un-approval.
--   2. Recreates ins_transition_claim to write those rows on approval and on
--      un-approval. Behaviour is otherwise unchanged: the status events,
--      paid/recognised guards, segregation-of-duties and amounts are untouched.
--      One new requirement: a re-approval (an approval that is not the claim's
--      first) must carry a reason explaining the change.
--   3. Backfills an initial row for every claim that is currently approved or
--      settled, dated at the claim's latest approval event (the only approval
--      evidence existing records have).
--   4. Recreates ins_report_claims_register so approved_amount is the latest
--      approval position on or before the as-at date (using the history), like
--      reserve_as_at already uses reserve history -- not the live claim value.
--
-- Nothing else about the claims workflow changes: ins_claim_events still
-- records the status transition, the register's status/open/ageing figures
-- are unchanged, and only the approved amount and its outstanding figure are
-- as-at.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------
create table public.ins_claim_approval_history (
    id uuid default gen_random_uuid() not null,
    tenant_id uuid not null,
    claim_id uuid not null,
    kind text not null,
    previous_amount numeric(18,2),
    new_amount numeric(18,2),
    reason text not null,
    note text,
    revised_by uuid default auth.uid(),
    effective_at timestamp with time zone default now() not null,
    created_at timestamp with time zone default now() not null,
    CONSTRAINT ins_claim_approval_history_kind_check
      CHECK ((kind = ANY (ARRAY['initial'::text, 'revision'::text, 'cleared'::text]))),
    CONSTRAINT ins_claim_approval_history_shape_check
      CHECK (((kind = 'initial'::text AND previous_amount IS NULL AND new_amount IS NOT NULL AND new_amount > (0)::numeric)
            OR (kind = 'revision'::text AND previous_amount IS NOT NULL AND new_amount IS NOT NULL AND new_amount > (0)::numeric)
            OR (kind = 'cleared'::text AND previous_amount IS NOT NULL AND new_amount IS NULL))),
    CONSTRAINT ins_claim_approval_history_reason_check
      CHECK (char_length(btrim(reason)) >= 1),
    CONSTRAINT ins_claim_approval_history_claim_fk
      FOREIGN KEY (tenant_id, claim_id) REFERENCES public.ins_claims(tenant_id, id) ON DELETE RESTRICT,
    CONSTRAINT ins_claim_approval_history_tenant_id_fkey
      FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE
);

COMMENT ON TABLE public.ins_claim_approval_history IS
  'One row per approval decision made on a claim (initial / revision) and one '
  'per un-approval (cleared). Immutable: written only from ins_transition_claim. '
  'effective_at is when the decision took effect (the approval event''s time); '
  'created_at is when the record was written.';

COMMENT ON COLUMN public.ins_claim_approval_history.note IS
  'The manager''s exact note, when they gave one. Nullable and distinct from '
  'reason on purpose: a blank note is NULL here while reason always carries a '
  'displayable value (the system fallback, unless a note was given).';

create index ins_claim_approval_history_claim_idx
  on public.ins_claim_approval_history using btree (tenant_id, claim_id, effective_at);

alter table public.ins_claim_approval_history enable row level security;

create policy ins_claim_approval_history_select on public.ins_claim_approval_history
  for select
  using ((tenant_id = public.get_my_tenant_id()) and public.can_access_insurance());

-- ---------------------------------------------------------------------
-- 2. Immutability: RPC-only, never edited or deleted
-- ---------------------------------------------------------------------
create or replace function public.ins_claim_approval_history_guard()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.ins_via_rpc() then
    raise exception 'INS_RPC_ONLY: change approval history with ins_transition_claim()' using errcode = '42501';
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    raise exception 'INS_APPROVAL_HISTORY_IMMUTABLE: approval history is never edited or deleted';
  end if;
  return new;
end $$;

drop trigger if exists ins_claim_approval_history_guard on public.ins_claim_approval_history;
create trigger ins_claim_approval_history_guard
  before insert or update or delete on public.ins_claim_approval_history
  for each row execute function public.ins_claim_approval_history_guard();

revoke all on function public.ins_claim_approval_history_guard() from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. Recreate ins_transition_claim with the approval-history writes
-- ---------------------------------------------------------------------
-- Body is identical to 20261031235900_squashed_baseline.sql (ins_transition_claim)
-- except: a re-approval must carry a reason, and every approval and every
-- un-approval writes a history row. Segregation of duties, guards and the
-- events table are unchanged.
create or replace function public.ins_transition_claim(p_claim_id uuid, p_to text, p_note text DEFAULT NULL::text, p_amount numeric DEFAULT NULL::numeric) RETURNS public.ins_claims
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
  v_prev_approved numeric;
  v_history_rows integer;
  v_approval_note text;
  v_kind       text;
  v_reason     text;
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

  -- A re-approval must carry a reason explaining the change. The first approval
  -- needs no note (the history row records the fallback reason).
  if p_to = 'approved' then
    select count(*) into v_history_rows from ins_claim_approval_history
     where claim_id = v_claim.id and tenant_id = v_tenant;
    if v_history_rows > 0 and nullif(btrim(p_note), '') is null then
      raise exception 'INS_NOTE_REQUIRED: give a reason for re-approving the claim at a new amount';
    end if;
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

    v_approval_note := nullif(btrim(p_note), '');

    -- History rows written here must always be a valid initial/revision pair.
    if v_history_rows = 0 then
      v_kind := 'initial';
      v_prev_approved := null;
    else
      v_kind := 'revision';
      select h.new_amount into v_prev_approved
        from public.ins_claim_approval_history h
       where h.claim_id = v_claim.id and h.tenant_id = v_tenant
         and h.new_amount is not null
       order by h.effective_at desc, h.id desc
       limit 1;
    end if;
    v_reason := coalesce(v_approval_note, 'Approved by claims manager');

    -- Approval does not create a receivable or payable. For a brokerage-managed claim
    -- the claim is 'approved, pending settlement' until ins_recognise_claim_receivable.
    update ins_claims set status = 'approved', approved_amount = p_amount, payment_mode = v_mode
     where id = v_claim.id returning * into v_claim;

    insert into public.ins_claim_approval_history (tenant_id, claim_id, kind, previous_amount, new_amount, reason, note, effective_at, created_at)
    values (v_tenant, v_claim.id, v_kind, v_prev_approved, p_amount, v_reason, v_approval_note, now(), now());
  elsif p_to = 'assessing' and v_from = 'approved' then
    -- Un-approval clears the decision. The history row records the withdrawal;
    -- nothing was posted, so nothing needs reversing.
    v_approval_note := nullif(btrim(p_note), '');
    insert into public.ins_claim_approval_history (tenant_id, claim_id, kind, previous_amount, new_amount, reason, note, effective_at, created_at)
    values (v_tenant, v_claim.id, 'cleared', v_claim.approved_amount, null, v_approval_note, v_approval_note, now(), now());

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

-- ---------------------------------------------------------------------
-- 4. Backfill: every claim currently approved or settled gets an initial
--    row, dated at its latest approval event. The only evidence for when the
--    approval took effect is the event, so the event's time is used; created_at
--    is today (the record is written by this migration).
-- ---------------------------------------------------------------------
select set_config('ins.via_rpc', 'on', true);

insert into public.ins_claim_approval_history (tenant_id, claim_id, kind, previous_amount, new_amount, reason, note, revised_by, effective_at, created_at)
select c.tenant_id, c.id, 'initial', null, c.approved_amount,
       'Approval at the time history was introduced', null,
       coalesce((select e.actor_id from public.ins_claim_events e
                  where e.claim_id = c.id and e.tenant_id = c.tenant_id and e.to_status = 'approved'
                  order by e.created_at desc, e.id desc limit 1), c.created_by),
       coalesce((select e.created_at from public.ins_claim_events e
                  where e.claim_id = c.id and e.tenant_id = c.tenant_id and e.to_status = 'approved'
                  order by e.created_at desc, e.id desc limit 1), c.created_at),
       now()
  from public.ins_claims c
 where c.approved_amount is not null
   and not exists (select 1 from public.ins_claim_approval_history h
                   where h.claim_id = c.id and h.tenant_id = c.tenant_id);

-- ---------------------------------------------------------------------
-- 5. ins_report_claims_register: approved_amount as at a date
-- ---------------------------------------------------------------------
-- Built on 20261121140000_ins_reports_kampala_dating.sql (Kampala dating, latest
-- tie-break). Only the approved amount and its outstanding figure change: they
-- come from the approval history (the latest approval position on or before the
-- as-at date) instead of the live claim value. Outstanding for an approved claim
-- is the approved-as-at less payments paid as at.
create or replace function public.ins_report_claims_register(
  p_as_of date default public.ins_local_today(),
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
               and public.ins_local_date(e.created_at) <= p_as_of
             order by e.created_at desc,
                      exists (select 1 from public.ins_claim_events n
                               where n.claim_id = e.claim_id and n.tenant_id = v_tenant
                                 and n.created_at = e.created_at
                                 and n.from_status = e.to_status and n.id <> e.id),
                      e.id desc
             limit 1) as status_at,
           (select public.ins_local_date(e.created_at)
              from public.ins_claim_events e
             where e.claim_id = c.id and e.tenant_id = v_tenant
               and public.ins_local_date(e.created_at) <= p_as_of
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
                 and public.ins_local_date(h.revised_at) <= p_as_of
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
                             or (p.status = 'void' and public.ins_local_date(p.voided_at) > p_as_of))), 0) as paid_at,
           (select case when r.kind = 'cleared' then null else r.new_amount end
              from (select h.kind, h.new_amount
                      from public.ins_claim_approval_history h
                     where h.claim_id = c.id and h.tenant_id = v_tenant
                       and public.ins_local_date(h.effective_at) <= p_as_of
                     order by h.effective_at desc,
                              exists (select 1 from public.ins_claim_approval_history n
                                       where n.claim_id = h.claim_id and n.tenant_id = v_tenant
                                         and n.effective_at = h.effective_at
                                         and n.previous_amount = coalesce(h.new_amount, h.previous_amount)
                                         and n.id <> h.id),
                              h.id desc
                     limit 1) r) as approved_at
      from public.ins_claims c
      join st on st.cid = c.id
  ),
  fin as (
    select k.*,
           (k.status_at in ('notified', 'assessing', 'approved')) as open_flag,
           case
             when k.status_at = 'approved'
               then greatest(coalesce(k.approved_at, 0) - k.paid_at, 0)
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
         case when f.status_at in ('approved', 'settled') then f.approved_at else null end,
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

-- ---------------------------------------------------------------------
-- 6. Grants and the tenant read-only guard
-- ---------------------------------------------------------------------
revoke all on table public.ins_claim_approval_history from public, anon, authenticated, service_role;
grant select on table public.ins_claim_approval_history to authenticated;
grant delete, insert, maintain, references, select, trigger, truncate, update
  on table public.ins_claim_approval_history to service_role;

select public.apply_tenant_read_only_guard();

select set_config('ins.via_rpc', '', true);

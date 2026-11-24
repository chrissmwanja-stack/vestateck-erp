-- =====================================================================
-- Refund approval limits and split prevention
-- Accountant pack v2, B7
-- =====================================================================
-- CENSUS FINDING THIS BUILD RESTS ON
--
-- A threshold-routing engine already exists: workflow_stages carries
-- threshold_amount, approver_role, sequence_order and low/high next-stage links,
-- with approval_assignments.threshold_max and approval_actions for decisions. All
-- 14 configured stages are procurement (applies_to='requests', roles such as Cost
-- Control Engineer and Procurement & Logistics Chief), so nothing insurance-side is
-- wired in -- but the machinery does not need rebuilding. This migration reuses the
-- stage table and adds only what the engine cannot hold.
--
-- WHY A SEPARATE DECISION LOG
--
-- approval_actions.request_id is NOT NULL and foreign-keyed to requests(id), the
-- procurement table. A refund is not a procurement request, so its approvals cannot
-- live there without inventing a dummy request row per refund. ins_refund_approvals
-- records the same shape (stage, level, approver, decision, comment, timestamp) and
-- adds only acted_on_behalf_of, which the pack's audit expectations need.
--
-- WHAT IS BUILT
--
--   workflow_stages.applies_to now accepts 'insurance_refunds', so limits are
--   configured the same way procurement limits are, by the same administrators,
--   with the same threshold_amount and approver_role columns.
--
--   ins_refund_requests      one row per refund asking for approval, carrying the
--                            level that applied when it was requested (so a later
--                            threshold change cannot retroactively alter what was
--                            approved).
--   ins_refund_approvals     the decision at each level.
--   ins_refund_required_level  which stage a given amount falls into.
--   ins_request_refund       raises the request and flags a possible split.
--   ins_decide_refund        approve or reject, refusing self-approval and
--                            requiring the stage's approver role.
--
--   AND the execution path is closed: ins_refund_client_advance (written in
--   20261124010300) now REFUSES a refund at or above the configured limit unless an
--   approved request covers it. Without that, the approval workflow would be
--   advisory and a client could be refunded by calling the refund function directly.
--
-- THE SPLIT CHECK is a flag, not a block, because the pack says "flagged as a
-- possible split". Two same-day refunds to the same payee, each individually below
-- the threshold, whose total would cross it, is the pattern the pack describes. It
-- is recorded on the request with the figures that triggered it, so the approver
-- sees why -- and it is never silently re-priced.
--
-- Also built, because B7's own criteria need it: a refund above the user's personal
-- limit routes to the next level. approval_assignments.threshold_max is read for
-- that: a user may approve up to their own maximum, and the stage's threshold is the
-- floor at which approval is required at all.

-- ---------------------------------------------------------------------
-- 1. Let workflow_stages carry insurance refund limits
-- ---------------------------------------------------------------------
alter table workflow_stages drop constraint if exists workflow_stages_applies_to_check;
alter table workflow_stages add constraint workflow_stages_applies_to_check
  check (applies_to in ('requests', 'invoices', 'insurance_refunds'));

-- Recognised approver_role values for insurance_refunds are the ones the two role
-- tables can actually hold: finance and cost_control (finance_team_members), or
-- admin, manager and member (staff_roles). A company admin may always decide. Any
-- other label leaves the refund approvable only by a company admin, and says so with
-- INS_REFUND_ROLE_UNCONFIGURED rather than failing obscurely.

comment on column workflow_stages.applies_to is
  'Which approval chain this stage belongs to. requests and invoices are procurement; insurance_refunds approves client refunds (accountant pack v2 B7).';

-- ---------------------------------------------------------------------
-- 2. The refund request
-- ---------------------------------------------------------------------
create table if not exists ins_refund_requests (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  refund_no         text not null,
  advance_id        uuid not null references ins_client_advances(id) on delete restrict,
  amount            numeric not null check (amount > 0),
  currency          char(3) not null,
  party_account_id  uuid not null references accounts(id),
  reason            text not null check (length(btrim(reason)) >= 5),
  status            text not null default 'pending'
                    check (status in ('pending', 'approved', 'rejected', 'cancelled', 'executed')),
  -- captured at request time so a later threshold edit cannot change what was approved
  required_stage_id uuid references workflow_stages(id),
  required_level    integer,
  required_role     text,
  -- possible split, recorded with its evidence
  split_flagged     boolean not null default false,
  split_detail      text,
  requested_by      uuid not null,
  requested_at      timestamptz not null default now(),
  decided_by        uuid,
  decided_at        timestamptz,
  decision_reason   text,
  settlement_id     uuid,
  constraint ins_refund_requests_self_check
    check (decided_by is null or decided_by <> requested_by),
  constraint ins_refund_requests_decided_check
    check (status = 'pending'
           or (decided_by is not null and decided_at is not null
               and (status = 'approved' or status = 'executed'
                    or length(btrim(decision_reason)) >= 5))),
  constraint ins_refund_requests_no_check unique (tenant_id, refund_no)
);

create index if not exists ins_refund_requests_party_idx
  on ins_refund_requests (tenant_id, party_account_id, requested_at);
create index if not exists ins_refund_requests_status_idx
  on ins_refund_requests (tenant_id, status);

create table if not exists ins_refund_approvals (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references tenants(id) on delete cascade,
  refund_id     uuid not null references ins_refund_requests(id) on delete cascade,
  stage_id      uuid references workflow_stages(id),
  level         integer not null,
  approver_id   uuid not null,
  acted_on_behalf_of uuid references app_users(id),
  decision      text not null check (decision in ('approved', 'rejected')),
  comment       text not null check (length(btrim(comment)) >= 3),
  decided_at    timestamptz not null default now(),
  constraint ins_refund_approvals_once unique (refund_id, level, approver_id)
);

create index if not exists ins_refund_approvals_refund_idx
  on ins_refund_approvals (tenant_id, refund_id);

alter table ins_refund_requests enable row level security;
alter table ins_refund_approvals enable row level security;

drop policy if exists ins_refund_requests_read on ins_refund_requests;
create policy ins_refund_requests_read on ins_refund_requests
  for select to authenticated using (tenant_id = get_my_tenant_id());

drop policy if exists ins_refund_approvals_read on ins_refund_approvals;
create policy ins_refund_approvals_read on ins_refund_approvals
  for select to authenticated using (tenant_id = get_my_tenant_id());

revoke insert, update, delete on ins_refund_requests from authenticated, anon;
revoke insert, update, delete on ins_refund_approvals from authenticated, anon;

comment on table ins_refund_requests is
  'Pack v2 B7. A refund above a configured limit needs approval from the stage its amount falls into, by someone other than the requester. The required stage is frozen at request time.';
comment on table ins_refund_approvals is
  'One row per approval decision. Not approval_actions, because that table requires a procurement request_id.';

-- ---------------------------------------------------------------------
-- 3. Which level an amount falls into
-- ---------------------------------------------------------------------
-- The highest configured stage whose threshold the amount reaches. Returning null
-- means no limit is configured for this company, and the ordinary finance role is
-- the only requirement -- which is exactly today's behaviour, so a company that
-- configures nothing is not silently blocked from refunding.
create or replace function public.platform_ins_refund_required_level(p_tenant_id uuid, p_amount numeric)
returns table (stage_id uuid, level integer, approver_role text, threshold_amount numeric)
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select s.id, s.sequence_order, s.approver_role, s.threshold_amount
    from workflow_stages s
   where s.tenant_id = p_tenant_id
     and s.applies_to = 'insurance_refunds'
     and s.is_active
     and coalesce(s.threshold_amount, 0) <= p_amount
   order by s.sequence_order desc
   limit 1
$$;

create or replace function public.ins_refund_required_level(p_amount numeric)
returns table (stage_id uuid, level integer, approver_role text, threshold_amount numeric)
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select * from public.platform_ins_refund_required_level(get_my_tenant_id(), p_amount)
$$;

-- The most a given user may approve on their own.
create or replace function public.platform_ins_refund_user_limit(p_tenant_id uuid, p_user_id uuid)
returns numeric
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select max(a.threshold_max)
    from approval_assignments a
    join workflow_stages s on s.id = a.workflow_stage_id
   where a.tenant_id = p_tenant_id
     and a.user_id = p_user_id
     and s.applies_to = 'insurance_refunds'
$$;

-- ---------------------------------------------------------------------
-- 4. Raising a refund request
-- ---------------------------------------------------------------------
create or replace function public.ins_request_refund(
  p_advance_id uuid,
  p_amount numeric,
  p_reason text
) returns ins_refund_requests
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_adv     ins_client_advances%rowtype;
  v_item    fin_open_items%rowtype;
  v_lvl     record;
  v_open    numeric;
  v_no      text;
  v_row     ins_refund_requests%rowtype;
  v_same_day_count integer;
  v_same_day_total numeric;
  v_threshold numeric;
begin
  if not is_finance_team_member('finance') then
    raise exception 'INS_REFUND_FINANCE: requesting a refund needs the finance role' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_REFUND_AMOUNT: the refund must be greater than zero';
  end if;
  if nullif(btrim(p_reason), '') is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_NOTE_REQUIRED: give the reason for the refund';
  end if;

  select * into v_adv from ins_client_advances
   where id = p_advance_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_ADVANCE_NOT_FOUND: advance % is not on this company', p_advance_id;
  end if;
  if v_adv.status = 'refunded' then
    raise exception 'INS_ADVANCE_REFUNDED: advance % has already been refunded', v_adv.id;
  end if;

  select * into v_item from fin_open_items
   where id = v_adv.open_item_id and tenant_id = v_tenant;
  v_open := v_adv.amount - public.fin_open_item_consumed(v_item.id);
  if p_amount > v_open then
    raise exception 'INS_ADVANCE_EXCEEDS: advance % has % available to refund, % requested',
      v_adv.id, v_open, p_amount;
  end if;

  select * into v_lvl from public.platform_ins_refund_required_level(v_tenant, p_amount);

  -- Possible split: other live refund requests to the same payee today, each below
  -- the threshold, whose combined total crosses it.
  v_threshold := coalesce(
    v_lvl.threshold_amount,
    (select min(s.threshold_amount)
       from public.workflow_stages s
      where s.tenant_id = v_tenant
        and s.applies_to = 'insurance_refunds'
        and s.is_active
        and coalesce(s.threshold_amount, 0) > p_amount));
  if v_threshold is not null then
    select count(*), coalesce(sum(r.amount), 0)
      into v_same_day_count, v_same_day_total
      from ins_refund_requests r
     where r.tenant_id = v_tenant
       and r.party_account_id = v_item.party_account_id
       and r.status in ('pending', 'approved')
       and public.business_date(r.requested_at) = public.business_today()
       and r.amount < v_threshold;
  end if;

  v_no := next_doc_number(v_tenant, 'ins_refund_request', 'RFD');
  perform set_config('ins.via_rpc', 'on', true);

  insert into ins_refund_requests (
    tenant_id, refund_no, advance_id, amount, currency, party_account_id, reason,
    status, required_stage_id, required_level, required_role,
    split_flagged, split_detail, requested_by
  ) values (
    v_tenant, v_no, v_adv.id, p_amount, v_adv.currency, v_item.party_account_id, btrim(p_reason),
    'pending', v_lvl.stage_id, v_lvl.level, v_lvl.approver_role,
    coalesce(v_same_day_count, 0) > 0
      and v_threshold is not null
      and (coalesce(v_same_day_total, 0) + p_amount) >= v_threshold,
    case when coalesce(v_same_day_count, 0) > 0 and v_threshold is not null
              and (coalesce(v_same_day_total, 0) + p_amount) >= v_threshold
         then format('%s other refund(s) to this payee today totalling %s, each below the %s limit; this one brings the day to %s',
                     v_same_day_count, v_same_day_total, v_threshold, v_same_day_total + p_amount)
         else null end,
    auth.uid()
  )
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Deciding a refund request
-- ---------------------------------------------------------------------
create or replace function public.ins_decide_refund(
  p_refund_id uuid,
  p_decision text,
  p_comment text
) returns ins_refund_requests
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_req     ins_refund_requests%rowtype;
  v_role_ok boolean;
  v_my_limit numeric;
begin
  if p_decision not in ('approve', 'reject') then
    raise exception 'INS_REFUND_DECISION: decision must be approve or reject';
  end if;
  if nullif(btrim(p_comment), '') is null or length(btrim(p_comment)) < 3 then
    raise exception 'INS_NOTE_REQUIRED: give a reason for the decision';
  end if;
  if not is_finance_team_member('finance') then
    raise exception 'INS_REFUND_FINANCE: deciding a refund needs the finance role' using errcode = '42501';
  end if;

  select * into v_req from ins_refund_requests
   where id = p_refund_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: refund request';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'INS_REFUND_STATE: refund % is %, not pending', v_req.refund_no, v_req.status;
  end if;

  -- Pack criterion: "the same user cannot approve it".
  if v_req.requested_by = auth.uid() then
    raise exception 'INS_REFUND_SELF: % requested this refund and cannot decide it', v_req.refund_no;
  end if;

  -- Pack criterion: "a refund above a user's limit routes to the next level".
  v_my_limit := public.platform_ins_refund_user_limit(v_tenant, auth.uid());
  if v_my_limit is not null and v_req.amount > v_my_limit then
    raise exception 'INS_REFUND_LIMIT: this refund is % but your approval limit is %; it must be approved at a higher level',
      v_req.amount, v_my_limit;
  end if;

  -- The approver must hold the role the stage names, when a stage applies.
  if v_req.required_role is not null then
    select exists (
      select 1 from app_users u
       where u.id = auth.uid() and u.tenant_id = v_tenant and coalesce(u.is_company_admin, false)
    ) or exists (
      select 1 from finance_team_members f
       where f.tenant_id = v_tenant and f.user_id = auth.uid() and f.role = v_req.required_role
    ) or exists (
      select 1 from staff_roles sr
       where sr.tenant_id = v_tenant and sr.user_id = auth.uid() and sr.role = v_req.required_role
    ) into v_role_ok;
    if not v_role_ok then
      -- Distinguish "you are the wrong person" from "nobody can approve this",
      -- which is what a misconfigured approver_role produces and what an operator
      -- needs to be told, rather than being left to guess at the role name.
      if exists (select 1 from finance_team_members f
                  where f.tenant_id = v_tenant and f.role = v_req.required_role)
         or exists (select 1 from staff_roles sr
                     where sr.tenant_id = v_tenant and sr.role = v_req.required_role) then
        raise exception 'INS_REFUND_ROLE: this refund needs the % role at level %; you do not hold it', v_req.required_role, v_req.required_level;
      else
        raise exception 'INS_REFUND_ROLE_UNCONFIGURED: this refund needs a stage configured with approver_role % at level %, but no user on this company holds that role. Either set the stage approver_role to finance, cost_control, admin, manager or member, or have a company admin decide it.',
          coalesce(v_req.required_role, '(none)'), coalesce(v_req.required_level, 1);
      end if;
    end if;
  end if;

  perform set_config('ins.via_rpc', 'on', true);

  insert into ins_refund_approvals (
    tenant_id, refund_id, stage_id, level, approver_id, decision, comment
  ) values (
    v_tenant, v_req.id, v_req.required_stage_id, coalesce(v_req.required_level, 1),
    auth.uid(), case p_decision when 'approve' then 'approved' else 'rejected' end, btrim(p_comment)
  );

  update ins_refund_requests
     set status = case p_decision when 'approve' then 'approved' else 'rejected' end,
         decided_by = auth.uid(),
         decided_at = now(),
         decision_reason = btrim(p_comment)
   where id = v_req.id
  returning * into v_req;

  return v_req;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Refunds are only raised and decided through these functions
-- ---------------------------------------------------------------------
create or replace function public.ins_refund_requests_guard() returns trigger
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'INS_REFUND_IMMUTABLE: refund requests are retained';
  end if;
  if not public.ins_via_rpc() then
    raise exception 'INS_RPC_ONLY: raise a refund with ins_request_refund() and decide it with ins_decide_refund()' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE'
     and (to_jsonb(new) - array['status', 'decided_by', 'decided_at', 'decision_reason', 'settlement_id'])
         is distinct from
         (to_jsonb(old) - array['status', 'decided_by', 'decided_at', 'decision_reason', 'settlement_id']) then
    raise exception 'INS_REFUND_IMMUTABLE: the amount, payee and basis of a refund cannot be changed after it is raised';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ins_refund_requests_guard on ins_refund_requests;
create trigger trg_ins_refund_requests_guard
  before insert or update or delete on ins_refund_requests
  for each row execute function ins_refund_requests_guard();

create or replace function public.ins_refund_approvals_guard() returns trigger
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    raise exception 'INS_REFUND_APPROVAL_IMMUTABLE: an approval decision is retained';
  end if;
  if not public.ins_via_rpc() then
    raise exception 'INS_RPC_ONLY: decide a refund with ins_decide_refund()' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ins_refund_approvals_guard on ins_refund_approvals;
create trigger trg_ins_refund_approvals_guard
  before insert or update or delete on ins_refund_approvals
  for each row execute function ins_refund_approvals_guard();

-- ---------------------------------------------------------------------
-- 7. Close the execution path
-- ---------------------------------------------------------------------
-- Without this the workflow is advisory: a client could be refunded by calling the
-- refund function directly and never raising a request. ins_refund_client_advance
-- now requires an approved request whenever a limit stage applies to the amount.
create or replace function public.ins_refund_client_advance(
  p_advance_id uuid,
  p_bank_account_id uuid,
  p_amount numeric,
  p_refunded_on date,
  p_reason text
) returns ins_client_advances
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_adv     ins_client_advances%rowtype;
  v_item    fin_open_items%rowtype;
  v_open    numeric;
  v_set     fin_settlements%rowtype;
  v_lvl     record;
  v_req     ins_refund_requests%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if not is_finance_team_member('finance') then
    raise exception 'INS_ADVANCE_FINANCE: refunding client money requires the finance role' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'INS_ADVANCE_REASON: a refund needs a reason';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_ADVANCE_AMOUNT: the refund must be greater than zero';
  end if;

  select * into v_adv from ins_client_advances
   where id = p_advance_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_ADVANCE_NOT_FOUND: advance % is not on this company', p_advance_id;
  end if;

  select * into v_item from fin_open_items
   where id = v_adv.open_item_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_ADVANCE_ITEM: the open item for advance % is missing', v_adv.id;
  end if;

  -- B7: an approved request is required wherever a limit stage applies.
  select * into v_lvl from public.platform_ins_refund_required_level(v_tenant, p_amount);
  if v_lvl.level is not null then
    -- Any approved request for this advance that has not been used yet. Deliberately
    -- not date-bounded: an approval granted yesterday is still an approval, and the
    -- request is consumed on execution below (status becomes 'executed').
    select * into v_req from ins_refund_requests
     where tenant_id = v_tenant
       and advance_id = v_adv.id
       and status = 'approved'
       and amount >= p_amount
     order by decided_at desc
     limit 1;
    if not found then
      raise exception 'INS_REFUND_APPROVAL_REQUIRED: refunding % needs an approved refund request at level % (%). Raise one with ins_request_refund() and have it approved.',
        p_amount, v_lvl.level, coalesce(v_lvl.approver_role, 'finance');
    end if;
  end if;

  v_open := public.fin_open_item_consumed(v_adv.open_item_id);
  if v_open + p_amount > v_adv.amount then
    raise exception 'INS_ADVANCE_EXCEEDS: advance % has % available to refund, % requested',
      v_adv.id, v_adv.amount - v_open, p_amount;
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  -- An ordinary client-money payment against the advance item, so the settlement
  -- guards (client-money bank only, approval, voidability) all apply to refunds.
  v_set := platform_fin_record_settlement_impl(
    v_tenant, p_bank_account_id, 'out', v_item.party_account_id, p_amount, p_refunded_on,
    jsonb_build_array(jsonb_build_object('open_item_id', v_adv.open_item_id, 'amount', p_amount)),
    null, p_reason);

  perform set_config('ins.via_rpc', 'on', true);
  update ins_client_advances
     set refunded_amount = refunded_amount + p_amount,
         refunded_at = now(),
         refund_journal_id = v_set.journal_entry_id,
         status = case when applied_amount + refunded_amount + p_amount >= amount
                       then 'refunded' else status end
   where id = v_adv.id
  returning * into v_adv;

  if v_req.id is not null then
    update ins_refund_requests
       set status = 'executed', settlement_id = v_set.id
     where id = v_req.id;
  end if;

  return v_adv;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Exposure
-- ---------------------------------------------------------------------
revoke all on function public.ins_refund_requests_guard() from public, anon, authenticated, service_role;
revoke all on function public.ins_refund_approvals_guard() from public, anon, authenticated, service_role;
revoke all on function public.platform_ins_refund_required_level(uuid, numeric) from public, anon, authenticated;
revoke all on function public.platform_ins_refund_user_limit(uuid, uuid) from public, anon, authenticated;
revoke all on function public.ins_refund_required_level(numeric) from public, anon;
revoke all on function public.ins_request_refund(uuid, numeric, text) from public, anon;
revoke all on function public.ins_decide_refund(uuid, text, text) from public, anon;

grant execute on function public.ins_refund_required_level(numeric) to authenticated;
grant execute on function public.ins_request_refund(uuid, numeric, text) to authenticated;
grant execute on function public.ins_decide_refund(uuid, text, text) to authenticated;

select public.apply_tenant_read_only_guard();

grant select on ins_refund_requests, ins_refund_approvals to authenticated;

-- =====================================================================
-- Currency in the approval routing key
-- Accountant pack v2, A11, condition C4 of AE5
-- =====================================================================
-- Section 11 asks for approval limits by "transaction type, amount, currency, role, approval
-- level and branch". Until now the routing key was amount and role only, which meant a company
-- operating in two currencies could not express the two limits it actually has. A single
-- threshold of 50,000,000 applied literally to shillings would never fire on a dollar journal,
-- and a threshold chosen to be sensible in dollars would fire almost immediately in shillings.
-- That is a real gap, not a wording one: the control degrades to "one limit for the largest
-- currency you use".
--
-- This migration adds currency to the key. It does NOT add branch or department, and the reason
-- is not laziness: a branch is a property of a user or a cost centre and the schema has no
-- unambiguous place to read "the branch of this journal" from, so inventing one would be a
-- policy decision dressed up as a column. Currency has no such problem -- every journal and
-- every refund already carries the currency of the money itself.

-- ---------------------------------------------------------------------
-- 1. A stage may be limited to one currency
-- ---------------------------------------------------------------------
-- NULL means "any currency", and that is the default for every existing row, so a company that
-- has configured nothing sees no change at all. A stage with a currency applies only to money
-- in that currency.
--
-- Deliberately NOT char(3): the rest of the schema's currency columns vary (ins_refund_requests
-- is char(3), fin_manual_journals is text) and this column has to compare against both. The
-- comparison goes through btrim/upper so 'ugx' and 'UGX ' match, because a currency code typed
-- by hand into an admin screen is exactly the kind of thing that arrives untrimmed.
alter table workflow_stages
  add column if not exists currency text;

comment on column workflow_stages.currency is
  'When set, this stage applies only to transactions in this currency. NULL means any currency, which is the default for every existing row, so amount-only routing is unchanged for a company that never sets it.';

-- ---------------------------------------------------------------------
-- 2. The routing lookup takes the currency of the money
-- ---------------------------------------------------------------------
-- The three-argument form has to be DROPPED rather than replaced: CREATE OR REPLACE cannot
-- change a parameter list, it would add an overload, and the old three-argument function would
-- survive and keep ignoring currency. A four-argument function with a default keeps every
-- existing three-argument caller working, and resolution is exact rather than ambiguous
-- precisely because the three-argument one is gone.
drop function if exists public.platform_approval_required_level(uuid, numeric, text);

create or replace function public.platform_approval_required_level(
  p_tenant_id uuid,
  p_amount numeric,
  p_applies_to text,
  p_currency text default null
) returns table (stage_id uuid, level integer, approver_role text, threshold_amount numeric, currency text)
    language plpgsql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_stage record;
begin
  select s.id, s.sequence_order, s.approver_role, s.threshold_amount, s.currency
    into v_stage
    from workflow_stages s
   where s.tenant_id = p_tenant_id
     and s.applies_to = p_applies_to
     and s.is_active
     and coalesce(s.threshold_amount, 0) <= p_amount
     -- FAIL CLOSED. When the caller does not say what currency the money is in, a currency-
     -- specific stage must not match: 'USD' = NULL is NULL, so the row is excluded and only the
     -- any-currency stages remain. Otherwise a company that configures a USD tier would have it
     -- applied to shilling journals by any caller that had not been updated to pass currency,
     -- which is the failure mode this whole migration exists to prevent.
     and (s.currency is null
          or btrim(upper(s.currency)) = btrim(upper(p_currency)))
   order by s.sequence_order desc
   limit 1;

  if found then
    return query select v_stage.id, v_stage.sequence_order, v_stage.approver_role,
                        v_stage.threshold_amount, v_stage.currency;
    return;
  end if;

  -- The minimum control for a client-advance refund (Appendix B Q2) survives untouched: it
  -- applies at the default level in the ledger currency and is not currency-specific, because
  -- "a refund always needs a second finance user" was never a statement about currency.
  if p_applies_to = 'insurance_refunds'
     and not exists (
       select 1 from public.workflow_stages s
        where s.tenant_id = p_tenant_id
          and s.applies_to = 'insurance_refunds'
          and s.is_active
     ) then
    return query select null::uuid, 1, 'finance'::text, null::numeric, null::text;
  end if;
end $$;

revoke all on function public.platform_approval_required_level(uuid, numeric, text, text) from public, anon, authenticated;
grant execute on function public.platform_approval_required_level(uuid, numeric, text, text) to service_role;

comment on function public.platform_approval_required_level(uuid, numeric, text, text) is
  'The highest active workflow stage a transaction of this amount, type and currency reaches. threshold_amount is compared per currency: a stage with currency set applies only to that currency, and a caller that passes no currency matches only any-currency stages, so a currency-specific tier can never be applied to the wrong money.';

-- ---------------------------------------------------------------------
-- 3. A currency-aware refund lookup, without breaking the old one
-- ---------------------------------------------------------------------
-- The refund helper needs a currency-aware form, and the obvious way to add one is a default
-- on a new third parameter. That does NOT work here, and the reason is worth recording because
-- it is invisible until it runs: a three-argument function with a default and an existing
-- two-argument function make a two-argument call AMBIGUOUS, and PostgreSQL refuses it with
-- 42725 "function ... is not unique". It does not silently prefer the shorter one. Every
-- existing two-argument caller would have broken at runtime, and nothing in a parse check or a
-- CREATE would have said so -- only an actual call.
--
-- So the shipped two-argument signature is KEPT exactly as it was, delegating with no currency,
-- and the currency-aware form is a four-argument function whose last parameter has a default.
-- 'platform_ins_refund_required_level(uuid, numeric)' and
-- 'platform_ins_refund_required_level(uuid, numeric, text, text)' are distinguishable at every
-- arity, so neither shadows the other.

-- The two-argument form keeps its return type EXACTLY as 011500 left it, which means it cannot
-- carry a currency column. That is not a compromise, it is the only shape that applies to an
-- already-provisioned database: the first version of this file widened the OUT list and
-- PostgreSQL refused with 42P13 'cannot change return type of existing function' -- while on a
-- fresh database the same statement succeeded. A migration that only works on an empty database
-- is not a migration. Callers that need the currency use the three-argument form below.
create or replace function public.platform_ins_refund_required_level(
  p_tenant_id uuid,
  p_amount numeric
) returns table (stage_id uuid, level integer, approver_role text, threshold_amount numeric)
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select stage_id, level, approver_role, threshold_amount
    from public.platform_approval_required_level(p_tenant_id, p_amount, 'insurance_refunds', null)
$$;

revoke all on function public.platform_ins_refund_required_level(uuid, numeric) from public, anon, authenticated;
grant execute on function public.platform_ins_refund_required_level(uuid, numeric) to service_role;

-- The currency-aware form, for a caller that knows what currency the money is in.
--
-- NO DEFAULTS HERE, and that is the whole point. A third parameter with a default makes the
-- function callable at arity 2 as well, which collides with the two-argument form above and
-- produces 42725 at CALL time -- not at CREATE time, so nothing catches it until something
-- calls it. Both of those shapes were tried and refused by the database before this was
-- written; the version below is the one that resolves. Three required parameters cannot be
-- confused with two.
create or replace function public.platform_ins_refund_required_level(
  p_tenant_id uuid,
  p_amount numeric,
  p_currency text
) returns table (stage_id uuid, level integer, approver_role text, threshold_amount numeric, currency text)
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select * from public.platform_approval_required_level(p_tenant_id, p_amount, 'insurance_refunds', p_currency)
$$;

revoke all on function public.platform_ins_refund_required_level(uuid, numeric, text) from public, anon, authenticated;
grant execute on function public.platform_ins_refund_required_level(uuid, numeric, text) to service_role;

-- ---------------------------------------------------------------------
-- 3b. ...and the decision must honour it
-- ---------------------------------------------------------------------
-- Re-issued from 20261124010800's own body. The ONLY change is section 3's level check and
-- the level recorded on the approval row; every guard above and below it -- self-approval,
-- user limit, role, mandatory reason, pending-only -- is reproduced unchanged, because a
-- re-issue that quietly drops one is worse than no re-issue at all.
--
-- What it fixes: required_level is captured when the request is raised and never revisited,
-- so a currency tier added later could not affect a request already in the queue. A USD refund
-- raised before anyone configured the USD stage would be signed at the shilling level.
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
  v_lvl     record;
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

  -- The level is re-resolved at decision time, in the currency of the money being refunded.
  --
  -- Required level, role and stage are captured when the request is raised, and a decision
  -- must not be one currency's approval standing in for another's. Without this the currency
  -- tier B14 added could still be bypassed on the decide side: a request raised before the
  -- stage existed (or by any path that had not been updated) would be signed off at the level
  -- recorded then, so a USD refund could be approved by whoever signs for shillings.
  --
  -- The request's own currency is used, which is the currency of the advance it refunds.
  -- When the company has no stage for this amount and currency, the lookup falls back to the
  -- minimum control (one finance user other than the requester), so this can only ever raise
  -- the bar, never waive it.
  select * into v_lvl from public.platform_ins_refund_required_level(
    v_tenant, v_req.amount, v_req.currency);
  if v_lvl.level is not null and coalesce(v_req.required_level, 1) < v_lvl.level then
    raise exception
      'INS_REFUND_LEVEL: this % refund of % reaches approval level % for its amount and currency, but was raised at level %; it must be re-raised so the right approvers see it',
      coalesce(nullif(btrim(v_req.currency), ''), 'ledger-currency'),
      v_req.amount, v_lvl.level, coalesce(v_req.required_level, 1);
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
    v_tenant, v_req.id, coalesce(v_lvl.stage_id, v_req.required_stage_id),
    greatest(coalesce(v_req.required_level, 1), coalesce(v_lvl.level, 1)),
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

revoke all on function public.ins_decide_refund(uuid, text, text) from public, anon;
grant execute on function public.ins_decide_refund(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. The chain reads the journal's own currency
-- ---------------------------------------------------------------------
create or replace function public.platform_manual_journal_chain_state(
  p_tenant_id uuid,
  p_journal_id uuid
) returns table (
  required_level  integer,
  approved_levels integer,
  next_level      integer,
  next_stage_id   uuid,
  next_role       text,
  complete        boolean,
  gap_levels      integer
)
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_amount   numeric;
  v_ccy      text;
  v_req      record;
  v_next     integer;
  v_stage_id uuid;
  v_role     text;
  v_gaps     integer;
begin
  select j.total_debit, j.currency into v_amount, v_ccy
    from public.fin_manual_journals j
   where j.id = p_journal_id and j.tenant_id = p_tenant_id;
  if not found then
    return;
  end if;

  -- The currency of this journal, so a USD tier cannot route a shilling entry. This is the
  -- line that makes condition C4 true for manual journals.
  select * into v_req
    from public.platform_approval_required_level(p_tenant_id, v_amount, 'manual_journals', v_ccy);

  if not found then
    return query select 0, 0, 0, null::uuid, null::text, true, 0;
    return;
  end if;

  select min(g) into v_next
    from generate_series(1, v_req.level) g
   where g not in (select a.level
                     from public.fin_manual_journal_approvals a
                    where a.journal_id = p_journal_id
                      and a.tenant_id = p_tenant_id
                      and a.decision = 'approved');
  v_next := coalesce(v_next, v_req.level);

  -- The stage for THAT level, in THAT currency. Defaulting to any-currency keeps a company that
  -- mixes both kinds of stage working: a level configured without a currency applies to every
  -- currency, and takes precedence being found when no currency-specific stage matches.
  select s.id, s.approver_role into v_stage_id, v_role
    from public.workflow_stages s
   where s.tenant_id = p_tenant_id
     and s.applies_to = 'manual_journals'
     and s.is_active
     and s.sequence_order = v_next
     and (s.currency is null
          or btrim(upper(s.currency)) = btrim(upper(v_ccy)))
   order by (s.currency is not null) desc
   limit 1;

  select count(*)::integer into v_gaps
    from generate_series(1, v_req.level) g
   where not exists (select 1
                       from public.workflow_stages s
                      where s.tenant_id = p_tenant_id
                        and s.applies_to = 'manual_journals'
                        and s.is_active
                        and s.sequence_order = g
                        and (s.currency is null
                             or btrim(upper(s.currency)) = btrim(upper(v_ccy))));

  return query
  with done as (
    select a.level
      from public.fin_manual_journal_approvals a
     where a.journal_id = p_journal_id
       and a.tenant_id = p_tenant_id
       and a.decision = 'approved'
     group by a.level
  )
  select v_req.level,
         (select count(*)::integer from done),
         v_next,
         v_stage_id,
         v_role,
         (select count(*) from done) >= v_req.level,
         v_gaps;
end $$;

revoke all on function public.platform_manual_journal_chain_state(uuid, uuid) from public, anon;
grant execute on function public.platform_manual_journal_chain_state(uuid, uuid) to authenticated;

comment on function public.platform_manual_journal_chain_state(uuid, uuid) is
  'How far through its approval chain a manual journal is: the level it routes to given the journal''s own amount and currency, how many levels are approved, which level is next, the stage id and role that level requires in that currency, whether the chain is satisfied, and how many sequence positions have no applicable active stage. complete = true with required_level = 0 means no chain applies, not that the journal is approved.';

-- ---------------------------------------------------------------------
-- 5. What this does not fix
-- ---------------------------------------------------------------------
--   * Branch and department are not in the key. A branch is not unambiguously readable from a
--     journal, and inventing a column to satisfy a checklist would put a control on a guess.
--   * (fixed in 5b) Two stages could occupy the same level and currency, leaving one silently
--     dead. Now refused by a partial unique index, and checked before the index is built so an
--     existing duplicate is reported with the tenant and level rather than surfacing as an
--     opaque constraint violation.
--   * The refund path is currency-aware on BOTH sides now: section 6 passes the advance's
--     currency when the request is raised, and section 3b re-resolves at the same currency when
--     it is decided. Before 3b the stage was applied at request time only, so a currency tier
--     could be bypassed by a request already in the queue.

-- ---------------------------------------------------------------------
-- 5b. Two stages may not claim the same level in the same currency
-- ---------------------------------------------------------------------
-- The hazard above is fixed for new rows rather than left documented. A company configuring
-- two stages at sequence_order 2 for UGX would have one of them silently dead: the lookup takes
-- the highest sequence_order under a limit 1, so the loser never approves anything and the
-- company believes it has a control it does not have.
--
-- '' and NULL are the same thing here -- "any currency" -- so the index coalesces, otherwise
-- ('ugx') and (NULL) and ('') could all sit at level 2 and the tier would be ambiguous.
--
-- Built as a UNIQUE INDEX ... WHERE a duplicate does not already exist, i.e. not at all on a
-- company that already has duplicates. A hard constraint would fail that company's deploy, and
-- refusing to deploy is not the same as fixing them; instead the check is verified below and
-- reports rather than guessing.
do $do$
declare
  v_dupes text;
begin
  select string_agg(format('tenant %s: applies_to %s level %s (%s stage(s))',
                            tenant_id, applies_to, sequence_order,
                            case when ccy = '' then 'any currency' else ccy end), '; ')
    into v_dupes
    from (select tenant_id, applies_to, sequence_order,
                 (coalesce(btrim(upper(currency)), '')) as ccy
            from public.workflow_stages
           where is_active
           group by tenant_id, applies_to, sequence_order,
                    (coalesce(btrim(upper(currency)), ''))
          having count(*) > 1) d;

  if v_dupes is not null then
    raise exception
      'WORKFLOW_STAGE_DUPLICATE: these active stages share a level and currency, so one is dead and the company''s control is weaker than it looks: %. Resolve them, then re-run this migration.',
      v_dupes;
  end if;
end
$do$;

create unique index if not exists workflow_stages_level_currency_uniq
  on public.workflow_stages (tenant_id, applies_to, sequence_order,
                             (coalesce(btrim(upper(currency)), '')))
  where is_active;

comment on index public.workflow_stages_level_currency_uniq is
  'One active stage per level per currency per chain. Without it two stages can occupy the same level and the lookup silently picks one, leaving the other dead while the company believes it is enforced. NULL and empty currency both mean "any currency" and are coalesced so they cannot coexist at one level.';

-- ---------------------------------------------------------------------
-- 6. The refund path passes the money's currency
-- ---------------------------------------------------------------------
-- A currency-specific REFUND stage is dead unless the request records which currency it is in
-- when it asks which level applies. Without this, section 5's third limitation would be true:
-- the stage would look configured and never fire.
--
-- ins_request_refund and its re-issue both resolve the level from the advance, and the advance
-- carries the currency of the money, so v_adv.currency is the right value in both places.
-- Re-issued here from their own sources so the bodies stay diffable against what shipped; the
-- ONLY change in each is the currency argument.
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

  -- The currency of the money being refunded, so a currency-specific stage applies to it.
  select * into v_lvl
    from public.platform_ins_refund_required_level(v_tenant, p_amount, v_adv.currency);

  -- Possible split: other live refund requests to the same payee today, each below
  -- the threshold, whose combined total crosses it.
  v_threshold := coalesce(
    v_lvl.threshold_amount,
    (select min(s.threshold_amount)
       from public.workflow_stages s
      where s.tenant_id = v_tenant
        and s.applies_to = 'insurance_refunds'
        and s.is_active
        and coalesce(s.threshold_amount, 0) > p_amount
        and (s.currency is null or btrim(upper(s.currency)) = btrim(upper(v_adv.currency)))));
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

revoke all on function public.ins_request_refund(uuid, numeric, text) from public, anon;
grant execute on function public.ins_request_refund(uuid, numeric, text) to authenticated;

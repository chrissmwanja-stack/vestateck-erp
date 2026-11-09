-- Re-apply three migrations that are recorded as applied in production but
-- whose effects are missing there, and reconcile one function regression.
--
-- Found 2026-10-02 by comparing a `supabase db pull` of production against the
-- repo. Same failure mode as the 2026-09-29 incident described in
-- supabase/tests/check_live_security_drift.sql: the versions are in
-- schema_migrations, but the files were edited after being recorded (or were
-- recorded without running), so the statements never ran.
--
--   20260925132000 fix_approval_attribution_effective_user
--       approval_actions.actor_id / effective_user_id / impersonation_session_id
--       do not exist in production, and record_approval_decision /
--       record_invoice_approval_decision do not record who really acted during
--       View-as.
--   20260925134000 add_missing_fk_indexes (the later "additional" half) and
--   20260928120200 add_remaining_fk_indexes
--       17 foreign-key indexes are missing in production.
--   20260928120100 reapply_announcement_dismissal_policies
--       platform_announcement_dismissals_delete_own does not exist, and the
--       select/insert policies still use bare auth.uid().
--
-- Why the two approval functions are NOT a verbatim copy of 20260925132000:
-- that file replaced them with simplified bodies (PO number built from the
-- request id instead of po_number_seq, no vendor_account_id, no duplicate-PO
-- guard, a missing next stage silently closes the request, a threshold stage
-- with no offer silently takes the low branch, the invoice workflow check is
-- gone). Production still runs the full logic from 20260910120000. Re-applying
-- the old file would have regressed procurement. The bodies below keep the
-- production logic and add only the attribution:
--   approver_id               = the real actor for a company-level session or a
--                               direct call, the impersonated user for a
--                               user-level session (what security_authorization.sql
--                               section E asserts)
--   actor_id                  = auth.uid()
--   effective_user_id         = effective_user_id()
--   impersonation_session_id  = the active View-as session, if any
-- and the offer-submitter / invoice-requester separation-of-duties checks now
-- compare the effective user, not only the real actor.
--
-- Existing approval_actions rows are backfilled as direct actions
-- (actor = effective = approver). Whether a historical row was made during
-- View-as cannot be recovered, so none are marked as impersonated.
--
-- Everything here is idempotent. Index builds take a brief SHARE lock on small
-- tables; run in a quiet moment if any of them has grown large.

begin;

-- 1. approval_actions attribution columns ------------------------------------
alter table public.approval_actions
  add column if not exists actor_id uuid,
  add column if not exists impersonation_session_id uuid,
  add column if not exists effective_user_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'approval_actions_impersonation_session_id_fkey'
      and conrelid = 'public.approval_actions'::regclass
  ) then
    alter table public.approval_actions
      add constraint approval_actions_impersonation_session_id_fkey
      foreign key (impersonation_session_id)
      references public.impersonation_sessions(id) on delete set null;
  end if;
end $$;

comment on column public.approval_actions.actor_id is 'Real authenticated user (auth.uid()) -- the operator when impersonating';
comment on column public.approval_actions.effective_user_id is 'Effective user for permission checks (effective_user_id()) -- target user when View-as user-level';
comment on column public.approval_actions.impersonation_session_id is 'Link to impersonation_sessions when the action occurred during View-as';

update public.approval_actions
set actor_id = approver_id,
    effective_user_id = approver_id
where actor_id is null;

-- 2. record_approval_decision: production logic + attribution -----------------
create or replace function public.record_approval_decision(
  p_request_id uuid,
  p_decision text,
  p_comment text default null,
  p_acting_on_behalf_of uuid default null,
  p_selected_offer_id uuid default null
)
returns table(out_request_id uuid, out_status text, out_stage_id uuid, out_purchase_order_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_request            requests%rowtype;
  v_stage              workflow_stages%rowtype;
  v_next_stage         workflow_stages%rowtype;
  v_next_stage_id      uuid;
  v_offer              request_offers%rowtype;
  v_po_id              uuid;
  v_po_number          text;
  v_actor              uuid := auth.uid();
  v_effective          uuid := public.effective_user_id();
  v_session_id         uuid;
  v_is_platform_bypass boolean := public.platform_admin_bypass();
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select id into v_session_id
  from impersonation_sessions
  where platform_admin_id = v_actor
    and ended_at is null
    and expires_at > now()
  order by started_at desc
  limit 1;

  select * into v_request from requests where id = p_request_id for update;
  if not found then
    raise exception 'request not found';
  end if;
  if v_request.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this request';
  end if;
  if v_request.status != 'open' then
    raise exception 'request is not open (status: %)', v_request.status;
  end if;
  if v_request.current_stage_id is null then
    raise exception 'request has no current stage';
  end if;
  if not can_act_on_stage(v_request.current_stage_id) then
    raise exception 'not authorized to act on this stage';
  end if;

  select * into v_stage from workflow_stages where id = v_request.current_stage_id;

  -- Anti-collusion: if this stage blocks the offer submitter from approving,
  -- check ALL offers on the request, against the effective identity.
  if v_stage.blocks_offer_submitter_approval then
    if exists (
      select 1 from request_offers
      where request_id = p_request_id and submitted_by = v_effective
    ) then
      raise exception 'you submitted an offer on this request -- a different reviewer must act on it at this stage';
    end if;
  end if;

  insert into approval_actions
    (request_id, workflow_stage_id, approver_id, actor_id, effective_user_id,
     impersonation_session_id, acted_on_behalf_of, decision, comment)
  values
    (p_request_id, v_stage.id,
     case when v_is_platform_bypass then v_actor else v_effective end,
     v_actor, v_effective, v_session_id,
     p_acting_on_behalf_of, p_decision, p_comment);

  if p_decision = 'rejected' then
    update requests set status = 'rejected', updated_at = now() where id = p_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'request_rejected',
      'Request rejected',
      format('Your request "%s" was rejected at the %s stage.', v_request.item_description, v_stage.name),
      p_request_id
    );

    if v_session_id is not null then
      perform log_platform_event(
        'request.reject.during_impersonation', v_request.tenant_id, 'request', p_request_id::text,
        p_comment,
        jsonb_build_object('stage', v_stage.name, 'actor', v_actor, 'effective', v_effective, 'session_id', v_session_id),
        jsonb_build_object('status', 'rejected')
      );
    end if;

    return query select p_request_id, 'rejected'::text, v_stage.id, null::uuid;
    return;
  end if;

  if v_stage.is_finance_terminal_stage then
    update requests
    set status = 'closed', current_stage_id = null, updated_at = now()
    where id = p_request_id;

    select id into v_po_id from purchase_orders where request_id = p_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'request_closed',
      'Request closed',
      format('Your request "%s" has been closed. The purchase order is ready for procurement.', v_request.item_description),
      p_request_id,
      v_po_id
    );

    return query select p_request_id, 'closed'::text, null::uuid, v_po_id;
    return;
  end if;

  -- Selection happens exactly once, at the stage flagged requires_offer_selection.
  -- Every other stage just reads whichever offer is currently marked selected.
  if v_stage.requires_offer_selection then
    if p_selected_offer_id is null then
      raise exception 'select a winning offer before approving';
    end if;
    if not exists (
      select 1 from request_offers
      where id = p_selected_offer_id and request_id = p_request_id
    ) then
      raise exception 'selected offer does not belong to this request';
    end if;

    update request_offers
    set is_selected = (id = p_selected_offer_id)
    where request_id = p_request_id;

    select * into v_offer from request_offers where id = p_selected_offer_id;
  else
    select * into v_offer from request_offers
    where request_id = p_request_id and is_selected
    limit 1;
  end if;

  if v_stage.threshold_amount is not null then
    if not found and v_offer.id is null then
      raise exception 'no offer on file to evaluate threshold';
    end if;
    if v_offer.quotation_amount <= v_stage.threshold_amount then
      v_next_stage_id := v_stage.next_stage_low_id;
    else
      v_next_stage_id := v_stage.next_stage_high_id;
    end if;
  else
    v_next_stage_id := v_stage.next_stage_low_id;
  end if;

  if v_next_stage_id is null then
    raise exception 'stage % has no next stage configured', v_stage.name;
  end if;

  select * into v_next_stage from workflow_stages where id = v_next_stage_id;

  if v_next_stage.is_finance_terminal_stage then
    if v_offer.id is null then
      raise exception 'no offer on file to generate a purchase order';
    end if;
    if exists (select 1 from purchase_orders where request_id = p_request_id) then
      raise exception 'a purchase order already exists for this request';
    end if;

    v_po_number := 'PO-' || to_char(now(), 'YYYY') || '-'
                   || lpad(nextval('public.po_number_seq')::text, 5, '0');

    insert into purchase_orders (request_id, po_number, vendor_name, vendor_account_id, amount, generated_by)
    values (p_request_id, v_po_number, v_offer.vendor_name, v_offer.vendor_account_id, v_offer.quotation_amount, v_actor)
    returning id into v_po_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, request_id, purchase_order_id)
    values (
      v_request.tenant_id,
      v_request.requester_id,
      'purchase_order_generated',
      'Purchase order generated',
      format('A purchase order (%s) has been generated for your request "%s".', v_po_number, v_request.item_description),
      p_request_id,
      v_po_id
    );
  end if;

  update requests
  set current_stage_id = v_next_stage_id, updated_at = now()
  where id = p_request_id;

  insert into notifications (tenant_id, recipient_id, type, title, body, request_id)
  select distinct
    v_request.tenant_id,
    recipient_id,
    'approval_needed',
    'Approval needed',
    format('Request "%s" is awaiting your approval at the %s stage.', v_request.item_description, v_next_stage.name),
    p_request_id
  from (
    select aa.user_id as recipient_id
    from approval_assignments aa
    where aa.workflow_stage_id = v_next_stage_id

    union

    select d.delegate_user_id as recipient_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and aa.workflow_stage_id = v_next_stage_id
      and (d.workflow_stage_id is null or d.workflow_stage_id = v_next_stage_id)
  ) recipients;

  return query select p_request_id, 'open'::text, v_next_stage_id, v_po_id;
end;
$function$;

revoke execute on function public.record_approval_decision(uuid, text, text, uuid, uuid) from public, anon;
grant execute on function public.record_approval_decision(uuid, text, text, uuid, uuid) to authenticated;

-- 3. record_invoice_approval_decision: production logic + attribution ---------
create or replace function public.record_invoice_approval_decision(
  p_invoice_request_id uuid,
  p_decision text,
  p_comment text default null,
  p_acting_on_behalf_of uuid default null
)
returns table(out_invoice_request_id uuid, out_status text, out_stage_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_invoice            invoice_requests%rowtype;
  v_stage              workflow_stages%rowtype;
  v_next_stage         workflow_stages%rowtype;
  v_next_stage_id      uuid;
  v_actor              uuid := auth.uid();
  v_effective          uuid := public.effective_user_id();
  v_session_id         uuid;
  v_is_platform_bypass boolean := public.platform_admin_bypass();
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;

  select id into v_session_id
  from impersonation_sessions
  where platform_admin_id = v_actor
    and ended_at is null
    and expires_at > now()
  order by started_at desc
  limit 1;

  select * into v_invoice from invoice_requests where id = p_invoice_request_id for update;
  if not found then
    raise exception 'invoice request not found';
  end if;
  if v_invoice.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this invoice request';
  end if;
  if v_invoice.status != 'open' then
    raise exception 'invoice request is not open (status: %)', v_invoice.status;
  end if;
  if v_invoice.current_stage_id is null then
    raise exception 'invoice request has no current stage';
  end if;
  if not can_act_on_stage(v_invoice.current_stage_id) then
    raise exception 'not authorized to act on this stage';
  end if;

  -- Submitter-block: whoever submitted the invoice may never approve or reject
  -- it, at any stage. Compared against the effective identity.
  if v_invoice.requester_id = v_effective then
    raise exception 'you submitted this invoice -- a different reviewer must act on it';
  end if;

  select * into v_stage from workflow_stages where id = v_invoice.current_stage_id;

  insert into approval_actions
    (invoice_request_id, workflow_stage_id, approver_id, actor_id, effective_user_id,
     impersonation_session_id, acted_on_behalf_of, decision, comment)
  values
    (p_invoice_request_id, v_stage.id,
     case when v_is_platform_bypass then v_actor else v_effective end,
     v_actor, v_effective, v_session_id,
     p_acting_on_behalf_of, p_decision, p_comment);

  if p_decision = 'rejected' then
    update invoice_requests set status = 'rejected', updated_at = now() where id = p_invoice_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
    values (
      v_invoice.tenant_id,
      v_invoice.requester_id,
      'invoice_rejected',
      'Invoice rejected',
      format('Your invoice for "%s" (%s) was rejected at the %s stage.', v_invoice.vendor_name, v_invoice.amount, v_stage.name),
      p_invoice_request_id
    );

    return query select p_invoice_request_id, 'rejected'::text, v_stage.id;
    return;
  end if;

  if v_stage.is_finance_terminal_stage then
    update invoice_requests
    set status = 'closed', current_stage_id = null, updated_at = now()
    where id = p_invoice_request_id;

    insert into notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
    values (
      v_invoice.tenant_id,
      v_invoice.requester_id,
      'invoice_closed',
      'Invoice closed',
      format('Your invoice for "%s" (%s) has been fully approved and closed.', v_invoice.vendor_name, v_invoice.amount),
      p_invoice_request_id
    );

    return query select p_invoice_request_id, 'closed'::text, null::uuid;
    return;
  end if;

  if v_stage.threshold_amount is not null then
    if v_invoice.amount <= v_stage.threshold_amount then
      v_next_stage_id := v_stage.next_stage_low_id;
    else
      v_next_stage_id := v_stage.next_stage_high_id;
    end if;
  else
    v_next_stage_id := v_stage.next_stage_low_id;
  end if;

  if v_next_stage_id is null then
    raise exception 'stage % has no next stage configured', v_stage.name;
  end if;

  select * into v_next_stage from workflow_stages where id = v_next_stage_id;

  if v_next_stage.applies_to != 'invoices' then
    raise exception 'stage % is not configured for the invoice workflow -- check workflow_stages config', v_next_stage.name;
  end if;

  update invoice_requests
  set current_stage_id = v_next_stage_id, updated_at = now()
  where id = p_invoice_request_id;

  insert into notifications (tenant_id, recipient_id, type, title, body, invoice_request_id)
  select distinct
    v_invoice.tenant_id,
    recipient_id,
    'approval_needed',
    'Approval needed',
    format('An invoice for "%s" (%s) is awaiting your approval at the %s stage.', v_invoice.vendor_name, v_invoice.amount, v_next_stage.name),
    p_invoice_request_id
  from (
    select aa.user_id as recipient_id
    from approval_assignments aa
    where aa.workflow_stage_id = v_next_stage_id

    union

    select d.delegate_user_id as recipient_id
    from approval_delegations d
    join approval_assignments aa on aa.user_id = d.delegator_user_id
    where d.status = 'active'
      and now() between d.starts_at and d.ends_at
      and aa.workflow_stage_id = v_next_stage_id
      and (d.workflow_stage_id is null or d.workflow_stage_id = v_next_stage_id)
  ) recipients;

  return query select p_invoice_request_id, 'open'::text, v_next_stage_id;
end;
$function$;

revoke execute on function public.record_invoice_approval_decision(uuid, text, text, uuid) from public, anon;
grant execute on function public.record_invoice_approval_decision(uuid, text, text, uuid) to authenticated;

-- 4. Announcement dismissal policies (same as 20260928120100) -----------------
drop policy if exists "platform_announcement_dismissals_select_own" on public.platform_announcement_dismissals;
create policy "platform_announcement_dismissals_select_own" on public.platform_announcement_dismissals
  for select using (user_id = (select auth.uid()));

drop policy if exists "platform_announcement_dismissals_insert_own" on public.platform_announcement_dismissals;
create policy "platform_announcement_dismissals_insert_own" on public.platform_announcement_dismissals
  for insert with check (user_id = (select auth.uid()));

drop policy if exists "platform_announcement_dismissals_delete_own" on public.platform_announcement_dismissals;
create policy "platform_announcement_dismissals_delete_own" on public.platform_announcement_dismissals
  for delete using (user_id = (select auth.uid()));

-- 5. Missing foreign-key indexes (from 20260925134000 and 20260928120200) -----
create index if not exists approval_actions_request_id_idx on public.approval_actions (request_id);
create index if not exists approval_actions_invoice_request_id_idx on public.approval_actions (invoice_request_id) where invoice_request_id is not null;
create index if not exists bd_tenders_client_id_idx on public.bd_tenders (client_id);
create index if not exists bd_opportunities_client_id_idx on public.bd_opportunities (client_id);
create index if not exists pmo_projects_category_id_idx on public.pmo_projects (category_id);
create index if not exists maintenance_requests_machine_id_idx on public.maintenance_requests (machine_id);
create index if not exists fuel_logs_machine_id_idx on public.fuel_logs (machine_id);
create index if not exists hr_employees_department_id_idx on public.hr_employees (department_id);
create index if not exists machine_maintenance_events_actor_id_idx on public.machine_maintenance_events (actor_id);
create index if not exists machine_maintenance_events_tenant_id_idx on public.machine_maintenance_events (tenant_id);
create index if not exists maintenance_requests_assigned_to_idx on public.maintenance_requests (assigned_to);
create index if not exists platform_announcements_tenant_id_idx on public.platform_announcements (tenant_id);
create index if not exists platform_job_runs_tenant_id_idx on public.platform_job_runs (tenant_id);
create index if not exists pmo_project_decisions_decided_by_idx on public.pmo_project_decisions (decided_by);
create index if not exists pmo_project_decisions_tenant_id_idx on public.pmo_project_decisions (tenant_id);
create index if not exists pmo_projects_created_by_idx on public.pmo_projects (created_by);
create index if not exists tenant_feature_flags_flag_key_idx on public.tenant_feature_flags (flag_key);

commit;
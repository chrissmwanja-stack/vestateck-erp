-- DB-level counterpart to the IT_ADMIN_ROLES frontend route split
-- (features/it-support/access.ts, App.tsx). Until now is_it_support()
-- was flat -- admin/manager/member all pass -- so even though the
-- frontend now hides ticket approvals and the categories/SLA/priority/
-- support-team admin screens from plain "member" IT staff, a member
-- could still call the underlying RPCs directly and approve tickets or
-- rewrite the lookup tables. This migration closes that gap at the RPC
-- layer, the same way the frontend closed it at the route layer.
--
-- Scope: only the *write* paths for ticket approvals and the four admin
-- tables (ticket_categories, sla_policies, priority_levels,
-- support_teams + support_team_members). The read RPCs
-- (get_ticket_categories, get_sla_policies, get_priority_levels,
-- get_support_teams) stay on the flat is_it_support() check -- they're
-- also used to populate dropdowns on ordinary ticket/asset screens that
-- every IT staff member (not just admin/manager) needs to reach, so
-- tightening them would break those screens for no security benefit
-- (the tables themselves carry nothing sensitive to read, only to
-- rewrite tenant-wide).
--
-- staff_roles.role has no hierarchy -- has_module_role() does an exact
-- `role = any(p_roles)` match -- so this needs its own function rather
-- than reusing is_it_support() with a narrower array inline at each call
-- site; a single named function keeps the tier in one place, same as
-- is_it_support() itself.

CREATE OR REPLACE FUNCTION "public"."is_it_support_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.has_module_role('it', array['admin','manager']);
$$;

ALTER FUNCTION "public"."is_it_support_admin"() OWNER TO "postgres";

REVOKE ALL ON FUNCTION "public"."is_it_support_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_it_support_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_it_support_admin"() TO "service_role";

COMMENT ON FUNCTION "public"."is_it_support_admin"() IS
  'Admin/manager-only counterpart to is_it_support() (which also passes plain ''member''). Gates ticket approvals and the ticket_categories/sla_policies/priority_levels/support_teams write RPCs -- see IT_ADMIN_ROLES in apps/web/src/features/it-support/access.ts for the matching frontend tier.';

-- Ticket approvals ----------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."get_pending_ticket_approvals"() RETURNS SETOF "public"."it_tickets"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select * from it_tickets
  where tenant_id = get_my_tenant_id() and is_it_support_admin() and approval_status = 'pending'
  order by created_at asc;
$$;

CREATE OR REPLACE FUNCTION "public"."record_ticket_approval"("p_ticket_id" "uuid", "p_decision" "text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."it_tickets"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_ticket public.it_tickets%rowtype;
begin
  if p_decision not in ('approved','rejected') then
    raise exception 'invalid decision: %', p_decision;
  end if;
  if not is_it_support_admin() then
    raise exception 'not authorized to approve tickets';
  end if;

  select * into v_ticket from it_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'ticket not found';
  end if;
  if v_ticket.tenant_id != get_my_tenant_id() then
    raise exception 'not authorized for this ticket';
  end if;
  if v_ticket.approval_status != 'pending' then
    raise exception 'ticket is not pending approval';
  end if;

  update it_tickets
  set approval_status = p_decision,
      approved_by = auth.uid(),
      approved_at = now(),
      approval_notes = p_notes,
      status = case when p_decision = 'rejected' then 'closed' else status end,
      resolution_notes = case when p_decision = 'rejected'
        then coalesce(resolution_notes, 'Rejected at approval: ' || coalesce(p_notes, 'no reason given'))
        else resolution_notes end,
      closed_at = case when p_decision = 'rejected' and closed_at is null then now() else closed_at end,
      updated_at = now()
  where id = p_ticket_id
  returning * into v_ticket;

  insert into notifications (tenant_id, recipient_id, type, title, body)
  values (
    v_ticket.tenant_id,
    v_ticket.requester_id,
    'ticket_approval_decision',
    'Ticket ' || v_ticket.ticket_number || ' ' || p_decision,
    format('Your ticket "%s" was %s.', v_ticket.subject, p_decision)
  );

  return v_ticket;
end;
$$;

-- Ticket categories -----------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."create_ticket_category"("p_code" "text", "p_name" "text") RETURNS "public"."ticket_categories"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.ticket_categories%rowtype;
begin
  if not is_it_support_admin() then
    raise exception 'not authorized to manage ticket categories';
  end if;
  insert into ticket_categories (tenant_id, code, name)
  values (get_my_tenant_id(), p_code, p_name)
  returning * into v_row;
  return v_row;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."update_ticket_category"("p_id" "uuid", "p_name" "text" DEFAULT NULL::"text", "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "public"."ticket_categories"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.ticket_categories%rowtype;
begin
  if not is_it_support_admin() then
    raise exception 'not authorized to manage ticket categories';
  end if;
  update ticket_categories
  set name = coalesce(p_name, name), is_active = coalesce(p_is_active, is_active)
  where id = p_id and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'ticket category not found';
  end if;
  return v_row;
end;
$$;

-- SLA policies ------------------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."upsert_sla_policy"("p_priority" "text", "p_target_hours" integer, "p_description" "text" DEFAULT NULL::"text") RETURNS "public"."sla_policies"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.sla_policies%rowtype;
begin
  if not is_it_support_admin() then
    raise exception 'not authorized to manage SLA policies';
  end if;
  if p_priority not in ('low','medium','high','urgent') then
    raise exception 'invalid priority: %', p_priority;
  end if;

  insert into sla_policies (tenant_id, priority, target_hours, description)
  values (get_my_tenant_id(), p_priority, p_target_hours, p_description)
  on conflict (tenant_id, priority)
  do update set target_hours = excluded.target_hours, description = excluded.description, updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

-- Priority levels -----------------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."update_priority_level"("p_code" "text", "p_label" "text" DEFAULT NULL::"text", "p_color" "text" DEFAULT NULL::"text") RETURNS "public"."priority_levels"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.priority_levels%rowtype;
begin
  if not is_it_support_admin() then
    raise exception 'not authorized to manage priority levels';
  end if;
  update priority_levels
  set label = coalesce(p_label, label), color = coalesce(p_color, color)
  where code = p_code and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'priority level not found';
  end if;
  return v_row;
end;
$$;

-- Support teams + membership ------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."create_support_team"("p_name" "text", "p_description" "text" DEFAULT NULL::"text") RETURNS "public"."support_teams"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.support_teams%rowtype;
begin
  if not is_it_support_admin() then
    raise exception 'not authorized to manage support teams';
  end if;
  insert into support_teams (tenant_id, name, description)
  values (get_my_tenant_id(), p_name, p_description)
  returning * into v_row;
  return v_row;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."update_support_team"("p_id" "uuid", "p_name" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "public"."support_teams"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row public.support_teams%rowtype;
begin
  if not is_it_support_admin() then
    raise exception 'not authorized to manage support teams';
  end if;
  update support_teams
  set name = coalesce(p_name, name), description = coalesce(p_description, description), is_active = coalesce(p_is_active, is_active)
  where id = p_id and tenant_id = get_my_tenant_id()
  returning * into v_row;
  if not found then
    raise exception 'support team not found';
  end if;
  return v_row;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."add_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support_admin() then
    raise exception 'not authorized to manage team membership';
  end if;
  if not exists (select 1 from support_teams where id = p_team_id and tenant_id = get_my_tenant_id()) then
    raise exception 'team not found';
  end if;
  insert into support_team_members (team_id, user_id) values (p_team_id, p_user_id)
  on conflict do nothing;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."remove_support_team_member"("p_team_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_it_support_admin() then
    raise exception 'not authorized to manage team membership';
  end if;
  delete from support_team_members
  where team_id = p_team_id and user_id = p_user_id
    and team_id in (select id from support_teams where tenant_id = get_my_tenant_id());
end;
$$;

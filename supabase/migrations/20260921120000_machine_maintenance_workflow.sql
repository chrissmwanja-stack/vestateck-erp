-- Machine Operation: maintenance workflow + cost rollup into the GL
-- (roadmap P2, last piece). Before:
--   * maintenance “scheduling” was a scheduled_date nobody was told about --
--     MaintenanceSchedule.tsx rendered an Overdue chip, and that was the
--     entire alerting strategy
--   * status flips were direct client UPDATEs (MaintenanceSchedule's
--     "Start" button, MaintenanceRequests' edit dialog) with no audit
--     trail, no completion cost capture
--   * fuel_logs.cost was captured but rolled up nowhere -- the Downtime
--     and Utilization reports count events, Finance never saw a shilling
--
-- This migration:
--   0. journal_entries.source_type CHECK widened with
--      'machine_fuel_log' + 'machine_maintenance_request' -- without it
--      every GL post below (and the insert/transition that triggered it)
--      would be rolled back.
--   1. maintenance_requests: + assigned_to, actual_cost,
--      overdue_notified_at (sweep idempotency marker).
--   2. machine_maintenance_events -- append-only status/cost audit
--      (tenant FK per rule 5, legal/filing shape).
--   3. transition_maintenance_request() RPC -- state machine
--        scheduled -> in_progress -> completed (captures actual_cost,
--        sets completed_date, posts to GL)
--        scheduled/in_progress -> cancelled
--      transitions any machine_operation role; COMPLETING with a cost is
--      admin/manager (it books money to the GL). Notifies requested_by /
--      assigned_to on every change.
--   4. Machine costs -> GL, following 20260904100000_gl_posting_rules'
--      pattern exactly: Dr default_expense, Cr ap_control, accounts
--      resolved via get_posting_account(), posted through the shared
--      post_journal_entry(); skipped silently when the tenant's posting
--      rules aren't complete yet. Fuel costs post on insert
--      (source_type 'machine_fuel_log'); maintenance actual_cost posts at
--      completion (source_type 'machine_maintenance_request').
--   5. machine_maintenance_overdue_sweep() -- a "cronless cron": any
--      module opener (MaintenanceSchedule calls it on mount) runs it; it
--      notifies the assignee/requester of every past-due open request
--      exactly once (overdue_notified_at), and returns the count. Ugandan
--      deployment reality: no pg_cron dependency, but nobody's overdue
--      maintenance goes unnoticed for more than a day in practice.

-- 0. journal_entries.source_type CHECK: the payroll workstream
--    (20260904090500) last set it to supplier_invoice / receivable_invoice /
--    cash_bank_transaction / opening_balance / manual / payroll_run. Without
--    this widening, every GL post below (and with it the fuel_logs INSERT or
--    maintenance completion that triggered it) would be rolled back.
ALTER TABLE "public"."journal_entries" DROP CONSTRAINT IF EXISTS "journal_entries_source_type_check";
ALTER TABLE "public"."journal_entries" ADD CONSTRAINT "journal_entries_source_type_check"
  CHECK (("source_type" = ANY (ARRAY['supplier_invoice'::"text", 'receivable_invoice'::"text", 'cash_bank_transaction'::"text", 'opening_balance'::"text", 'manual'::"text", 'payroll_run'::"text", 'machine_fuel_log'::"text", 'machine_maintenance_request'::"text"])));

-- 1. New columns
ALTER TABLE "public"."maintenance_requests"
  ADD COLUMN IF NOT EXISTS "assigned_to" "uuid" REFERENCES "public"."app_users"("id"),
  ADD COLUMN IF NOT EXISTS "actual_cost" "numeric"(14,2),
  ADD COLUMN IF NOT EXISTS "overdue_notified_at" timestamp with time zone;

-- 2. Audit table
CREATE TABLE IF NOT EXISTS "public"."machine_maintenance_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL REFERENCES "public"."tenants"("id") ON DELETE CASCADE,
    "request_id" "uuid" NOT NULL REFERENCES "public"."maintenance_requests"("id") ON DELETE CASCADE,
    "status" "text" NOT NULL,
    "actor_id" "uuid" NOT NULL REFERENCES "public"."app_users"("id"),
    "note" "text",
    "actual_cost" "numeric"(14,2),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "machine_maintenance_events_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "machine_maintenance_events_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'in_progress'::"text", 'completed'::"text", 'cancelled'::"text"])))
);

ALTER TABLE "public"."machine_maintenance_events" OWNER TO "postgres";
ALTER TABLE "public"."machine_maintenance_events" ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS "machine_maintenance_events_request_idx"
  ON "public"."machine_maintenance_events" ("request_id", "created_at");

CREATE POLICY "machine_maintenance_events_select" ON "public"."machine_maintenance_events"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('machine_operation'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- 3. State machine + GL posting on completion
CREATE OR REPLACE FUNCTION "public"."transition_maintenance_request"("p_request_id" "uuid", "p_status" "text", "p_note" "text" DEFAULT NULL, "p_actual_cost" "numeric" DEFAULT NULL)
RETURNS "public"."maintenance_requests"
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_req public.maintenance_requests%rowtype;
  v_allowed boolean;
  v_expense uuid;
  v_ap uuid;
  v_lines jsonb;
  v_machine_label text;
begin
  if not has_module_role('machine_operation', array['admin', 'manager', 'member']) then
    raise exception 'not authorized: machine operation role required';
  end if;

  select * into v_req from maintenance_requests
  where id = p_request_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'maintenance request not found in this tenant';
  end if;

  v_allowed := (v_req.status = 'scheduled'   and p_status = 'in_progress')
            or (v_req.status = 'in_progress' and p_status = 'completed')
            or (v_req.status in ('scheduled', 'in_progress') and p_status = 'cancelled');

  if not v_allowed then
    raise exception 'invalid maintenance transition: % -> %', v_req.status, p_status;
  end if;

  -- Completing books money to the GL when a cost is given, so it needs
  -- the same tier that writes every other machine money record.
  if p_status = 'completed' and p_actual_cost is not null then
    if p_actual_cost < 0 then
      raise exception 'actual_cost cannot be negative';
    end if;
    if not has_module_role('machine_operation', array['admin', 'manager']) then
      raise exception 'completing with a cost requires a machine operation admin or manager role';
    end if;
  end if;

  update maintenance_requests
  set status = p_status,
      completed_date = case when p_status = 'completed' then current_date else completed_date end,
      actual_cost = case when p_status = 'completed' then coalesce(p_actual_cost, actual_cost) else actual_cost end,
      updated_at = now()
  where id = v_req.id
  returning * into v_req;

  insert into machine_maintenance_events (tenant_id, request_id, status, actor_id, note, actual_cost)
  values (v_req.tenant_id, v_req.id, p_status, auth.uid(), nullif(btrim(coalesce(p_note, '')), ''), p_actual_cost);

  -- Notify the requester and/or assignee (deduped) about the change.
  insert into notifications (tenant_id, recipient_id, type, title, body)
  select distinct on (recipient) v_req.tenant_id, recipient,
    'maintenance_' || p_status,
    'Maintenance ' || p_status || ': ' || m.machine_no,
    format('Maintenance request "%s" on machine %s - %s is now %s.%s',
      left(v_req.description, 80), m.machine_no, m.name, p_status,
      case when p_status = 'completed' and v_req.actual_cost is not null
           then ' Actual cost recorded: ' || v_req.actual_cost::text else '' end)
  from machines m,
       (values (v_req.requested_by), (v_req.assigned_to)) as rec(recipient)
  where m.id = v_req.machine_id
    and recipient is not null
    and recipient <> auth.uid(); -- don't notify yourself about your own action

  -- GL posting on completion with a cost: Dr default expense / Cr AP
  -- control, same legs as a non-VAT supplier invoice, resolved through
  -- gl_posting_rules (20260904100000 replaced gl_control_accounts). Skip
  -- silently when the tenant hasn't finished their posting rules yet
  -- (mirror of trg_post_supplier_invoice's behaviour).
  if p_status = 'completed' and v_req.actual_cost is not null and v_req.actual_cost > 0 then
    v_expense := get_posting_account(v_req.tenant_id, 'default_expense');
    v_ap := get_posting_account(v_req.tenant_id, 'ap_control');
    if v_expense is not null and v_ap is not null then
      select machine_no || ' - ' || name into v_machine_label from machines where id = v_req.machine_id;
      v_lines := jsonb_build_array(
        jsonb_build_object('gl_account_id', v_expense, 'debit', v_req.actual_cost),
        jsonb_build_object('gl_account_id', v_ap, 'credit', v_req.actual_cost)
      );
      perform post_journal_entry(v_req.tenant_id, 'machine_maintenance_request', v_req.id,
        coalesce(v_req.completed_date, current_date),
        'Machine maintenance: ' || coalesce(v_machine_label, v_req.machine_id::text) || ' -- ' || left(v_req.description, 90), v_lines);
    end if;
  end if;

  return v_req;
end;
$$;

ALTER FUNCTION "public"."transition_maintenance_request"("uuid", "text", "text", "numeric") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."transition_maintenance_request"("uuid", "text", "text", "numeric") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."transition_maintenance_request"("uuid", "text", "text", "numeric") FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."transition_maintenance_request"("uuid", "text", "text", "numeric") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."transition_maintenance_request"("uuid", "text", "text", "numeric") TO "service_role";

COMMENT ON FUNCTION "public"."transition_maintenance_request"("uuid", "text", "text", "numeric") IS
  'Moves a maintenance request scheduled -> in_progress -> completed (or -> cancelled), auditing every step, notifying requester/assignee, and posting completed costs to the GL. Transitions: any machine_operation role; completing with a cost: admin/manager.';

-- 4. Fuel cost auto-post (same shape as trg_post_supplier_invoice)
CREATE OR REPLACE FUNCTION public.trg_post_machine_fuel()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_expense uuid;
  v_ap uuid;
  v_lines jsonb;
  v_machine_label text;
BEGIN
  IF NEW.cost IS NULL OR NEW.cost <= 0 THEN
    RETURN NEW; -- uncosted fuel: quantity tracking only
  END IF;

  v_expense := get_posting_account(NEW.tenant_id, 'default_expense');
  v_ap := get_posting_account(NEW.tenant_id, 'ap_control');
  IF v_expense IS NULL OR v_ap IS NULL THEN
    RETURN NEW; -- posting rules not set up yet; skip, don't fail the insert
  END IF;

  SELECT machine_no || ' - ' || name INTO v_machine_label
  FROM machines WHERE id = NEW.machine_id;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_expense, 'debit', NEW.cost),
    jsonb_build_object('gl_account_id', v_ap, 'credit', NEW.cost)
  );

  PERFORM post_journal_entry(NEW.tenant_id, 'machine_fuel_log', NEW.id, NEW.log_date,
    'Machine fuel: ' || coalesce(v_machine_label, NEW.machine_id::text), v_lines);

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_post_machine_fuel
AFTER INSERT ON public.fuel_logs
FOR EACH ROW EXECUTE FUNCTION public.trg_post_machine_fuel();

-- 5. Overdue sweep (idempotent, callable by any module member)
CREATE OR REPLACE FUNCTION "public"."machine_maintenance_overdue_sweep"()
RETURNS integer
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_req record;
  v_count int := 0;
begin
  if not has_module_role('machine_operation', array['admin', 'manager', 'member']) then
    return 0; -- outsiders just get nothing
  end if;

  for v_req in
    select r.*, m.machine_no, m.name as machine_name
    from maintenance_requests r
    join machines m on m.id = r.machine_id
    where r.tenant_id = get_my_tenant_id()
      and r.status in ('scheduled', 'in_progress')
      and r.scheduled_date is not null
      and r.scheduled_date < current_date
      and r.overdue_notified_at is null
  loop
    insert into notifications (tenant_id, recipient_id, type, title, body)
    select distinct on (recipient) v_req.tenant_id, recipient,
      'maintenance_overdue',
      'Maintenance overdue: ' || v_req.machine_no,
      format('"%s" on machine %s - %s was scheduled for %s and is %s day(s) overdue.',
        left(v_req.description, 80), v_req.machine_no, v_req.machine_name,
        v_req.scheduled_date::text, (current_date - v_req.scheduled_date)::text)
    from (values (v_req.requested_by), (v_req.assigned_to)) as rec(recipient)
    where recipient is not null;

    update maintenance_requests
    set overdue_notified_at = now()
    where id = v_req.id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

ALTER FUNCTION "public"."machine_maintenance_overdue_sweep"() OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."machine_maintenance_overdue_sweep"() FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."machine_maintenance_overdue_sweep"() FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."machine_maintenance_overdue_sweep"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."machine_maintenance_overdue_sweep"() TO "service_role";

COMMENT ON FUNCTION "public"."machine_maintenance_overdue_sweep"() IS
  'Notifies requester/assignee of every open past-due maintenance request exactly once (overdue_notified_at). Called by MaintenanceSchedule on mount; returns the number of requests newly flagged.';

-- PMO project approval flow (roadmap P2). Mirrors the law-compliance
-- contract flow shipped the same day
-- (20260921100000_law_contract_approval_flow.sql) -- same shape, same
-- separation-of-duties rule:
--
--   not_started --(submit)--> pending_approval --(approve)--> in_progress
--                                              \-(reject)--> rejected
--   rejected --(resubmit)--> pending_approval
--
-- Before this, projects appeared and were scheduled/resourced/spent
-- against with no sign-off step at all: NewProject could mark a project
-- in_progress directly, and any pmo admin/manager could edit any status
-- at will with no record of who changed what.
--
--   1. pmo_projects gains created_by -- it never tracked an originator,
--      so no one could be held to the "you can't approve your own
--      project" rule (NewProject.tsx now sets it; existing rows stay NULL,
--      which the RPCs treat as "no owner to conflict with").
--
--   2. status enum grows pending_approval / rejected (existing lifecycle
--      untouched: in_progress / on_hold / completed / cancelled stay
--      ordinary manager-controlled states).
--
--   3. pmo_project_decisions -- append-only audit trail
--      ('submitted' | 'approved' | 'rejected', actor, notes, timestamp).
--      RLS: tenant + pmo module read; writes only through the RPCs.
--
--   4. submit_pmo_project_for_approval / decide_pmo_project -- SECURITY
--      DEFINER RPCs. Decide is pmo admin/manager tier and refuses:
--      deciding anything not pending_approval, deciding a project you
--      created (self-approval), rejection without a reason. Approval
--      activates the project (in_progress); both outcomes notify the
--      creator inline (there is no notify trigger for pmo_* like the one
--      law_contracts has -- kept in the RPC instead of adding another
--      trigger family).

-- 1. Originator tracking
ALTER TABLE "public"."pmo_projects"
  ADD COLUMN IF NOT EXISTS "created_by" "uuid" REFERENCES "public"."app_users"("id");

-- 2. New statuses
ALTER TABLE "public"."pmo_projects" DROP CONSTRAINT "pmo_projects_status_check";
ALTER TABLE "public"."pmo_projects" ADD CONSTRAINT "pmo_projects_status_check"
  CHECK (("status" = ANY (ARRAY[
    'not_started'::"text",
    'pending_approval'::"text",
    'in_progress'::"text",
    'on_hold'::"text",
    'completed'::"text",
    'cancelled'::"text",
    'rejected'::"text"
  ])));

-- 3. Audit table
CREATE TABLE IF NOT EXISTS "public"."pmo_project_decisions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL REFERENCES "public"."tenants"("id") ON DELETE CASCADE,
    "project_id" "uuid" NOT NULL REFERENCES "public"."pmo_projects"("id") ON DELETE CASCADE,
    "decision" "text" NOT NULL,
    "decided_by" "uuid" NOT NULL REFERENCES "public"."app_users"("id"),
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pmo_project_decisions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "pmo_project_decisions_decision_check" CHECK (("decision" = ANY (ARRAY['submitted'::"text", 'approved'::"text", 'rejected'::"text"])))
);

ALTER TABLE "public"."pmo_project_decisions" OWNER TO "postgres";
ALTER TABLE "public"."pmo_project_decisions" ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS "pmo_project_decisions_project_idx"
  ON "public"."pmo_project_decisions" ("project_id", "created_at");

CREATE POLICY "pmo_project_decisions_select" ON "public"."pmo_project_decisions"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- 4a. Submit (or resubmit after rejection)
CREATE OR REPLACE FUNCTION "public"."submit_pmo_project_for_approval"("p_project_id" "uuid")
RETURNS "public"."pmo_projects"
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_project public.pmo_projects%rowtype;
begin
  if not has_module_role('pmo', array['admin', 'manager', 'member']) then
    raise exception 'not authorized: pmo module role required';
  end if;

  select * into v_project from pmo_projects
  where id = p_project_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'project not found in this tenant';
  end if;
  if v_project.status not in ('not_started', 'rejected') then
    raise exception 'only not_started or rejected projects can be submitted (current status: %)', v_project.status;
  end if;

  update pmo_projects
  set status = 'pending_approval', updated_at = now()
  where id = v_project.id
  returning * into v_project;

  insert into pmo_project_decisions (tenant_id, project_id, decision, decided_by, notes)
  values (v_project.tenant_id, v_project.id, 'submitted', auth.uid(), null);

  return v_project;
end;
$$;

ALTER FUNCTION "public"."submit_pmo_project_for_approval"("uuid") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."submit_pmo_project_for_approval"("uuid") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."submit_pmo_project_for_approval"("uuid") FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."submit_pmo_project_for_approval"("uuid") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."submit_pmo_project_for_approval"("uuid") TO "service_role";

COMMENT ON FUNCTION "public"."submit_pmo_project_for_approval"("uuid") IS
  'Moves a not_started (or previously rejected) pmo project to pending_approval and records a submitted decision row. Any pmo module role; same-tenant only.';

-- 4b. Decide
CREATE OR REPLACE FUNCTION "public"."decide_pmo_project"("p_project_id" "uuid", "p_decision" "text", "p_notes" "text" DEFAULT NULL)
RETURNS "public"."pmo_projects"
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_project public.pmo_projects%rowtype;
begin
  if not has_module_role('pmo', array['admin', 'manager']) then
    raise exception 'not authorized: project approval requires a pmo admin or manager role';
  end if;

  if p_decision not in ('approved', 'rejected') then
    raise exception 'p_decision must be ''approved'' or ''rejected''';
  end if;

  if p_decision = 'rejected' and (p_notes is null or btrim(p_notes) = '') then
    raise exception 'rejection requires notes explaining why';
  end if;

  select * into v_project from pmo_projects
  where id = p_project_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'project not found in this tenant';
  end if;
  if v_project.status <> 'pending_approval' then
    raise exception 'only projects pending approval can be decided (current status: %)', v_project.status;
  end if;

  -- Separation of duties: the originator of a project must not be the one
  -- approving its budget/resources, even with an approver role.
  if v_project.created_by is not null and v_project.created_by = auth.uid() then
    raise exception 'you cannot decide a project you created -- another pmo admin/manager must approve it';
  end if;

  update pmo_projects
  set status = case p_decision when 'approved' then 'in_progress' else 'rejected' end,
      updated_at = now()
  where id = v_project.id
  returning * into v_project;

  insert into pmo_project_decisions (tenant_id, project_id, decision, decided_by, notes)
  values (v_project.tenant_id, v_project.id, p_decision, auth.uid(), nullif(btrim(coalesce(p_notes, '')), ''));

  if v_project.created_by is not null then
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (
      v_project.tenant_id,
      v_project.created_by,
      'pmo_project_' || p_decision,
      (case p_decision when 'approved' then 'Project approved: ' else 'Project rejected: ' end) || v_project.project_no,
      case p_decision
        when 'approved' then format('Project "%s" (%s) has been approved and is now in progress.', v_project.name, v_project.project_no)
        else format('Project "%s" (%s) was rejected.%s', v_project.name, v_project.project_no,
                    case when nullif(btrim(coalesce(p_notes, '')), '') is not null
                         then ' Reason: ' || btrim(p_notes) else '' end)
      end
    );
  end if;

  return v_project;
end;
$$;

ALTER FUNCTION "public"."decide_pmo_project"("uuid", "text", "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."decide_pmo_project"("uuid", "text", "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."decide_pmo_project"("uuid", "text", "text") FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."decide_pmo_project"("uuid", "text", "text") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."decide_pmo_project"("uuid", "text", "text") TO "service_role";

COMMENT ON FUNCTION "public"."decide_pmo_project"("uuid", "text", "text") IS
  'Approves (in_progress) or rejects a pending_approval pmo project with an audit row and a creator notification. Pmo admin/manager only; creator may not self-approve; rejection requires notes.';

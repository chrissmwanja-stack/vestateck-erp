-- PMO cost & time ledger (roadmap P2) -- replaces the fake "actual" in the
-- Budget vs Actual report, which was literally earned value
-- (budget * completion%) with a different label, so a project could never
-- be over budget. Now actuals come from two real ledgers:
--
--   pmo_time_entries   -- hours logged by a user against a project (or a
--      specific task), each carrying an hourly_rate snapshot. The
--      BEFORE-INSERT trigger pmo_time_entry_apply_rate() fills the
--      snapshot from the logger's active resource allocation
--      (pmo_resource_allocations.hourly_rate, added here); when no
--      allocation/rate exists the entry is logged uncosted (NULL rate =
--      hours tracked, zero cost -- never silently guessed).
--
--   pmo_cost_entries   -- direct project costs (materials, equipment,
--      subcontractor, travel, labor, other). Money enters only through
--      pmo admin/manager hands; everyone can log their own time.
--
-- RLS shape (mirrors leave/attendance conventions, keeping rule 4's
-- per-verb split):
--   time entries: SELECT pmo members OR logger; INSERT own rows only
--     (user_id = auth.uid()); UPDATE/DELETE own rows OR pmo
--     admin/manager for corrections.
--   cost entries: SELECT pmo members; INSERT/UPDATE/DELETE pmo
--     admin/manager (same tier as every other pmo write).
-- Read access piggybacks on the P1 module-gated SELECT policies: if you
-- can't read the project you can't reach its ledger.

ALTER TABLE "public"."pmo_resource_allocations"
  ADD COLUMN IF NOT EXISTS "hourly_rate" "numeric"(12,2);

-- ---------------------------------------------------------------------
-- Time entries
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "public"."pmo_time_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL REFERENCES "public"."tenants"("id") ON DELETE CASCADE,
    "project_id" "uuid" NOT NULL REFERENCES "public"."pmo_projects"("id") ON DELETE CASCADE,
    "task_id" "uuid" REFERENCES "public"."pmo_tasks"("id") ON DELETE SET NULL,
    "user_id" "uuid" NOT NULL REFERENCES "public"."app_users"("id"),
    "entry_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "hours" "numeric"(5,2) NOT NULL,
    "note" "text",
    "hourly_rate" "numeric"(12,2),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pmo_time_entries_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "pmo_time_entries_hours_check" CHECK ((("hours" > (0)::numeric) AND ("hours" <= (24)::numeric)))
);

ALTER TABLE "public"."pmo_time_entries" OWNER TO "postgres";
ALTER TABLE "public"."pmo_time_entries" ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS "pmo_time_entries_project_idx"
  ON "public"."pmo_time_entries" ("project_id", "entry_date");
CREATE INDEX IF NOT EXISTS "pmo_time_entries_user_idx"
  ON "public"."pmo_time_entries" ("user_id", "entry_date");

CREATE OR REPLACE FUNCTION public.pmo_time_entry_apply_rate()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.hourly_rate IS NULL THEN
    SELECT a.hourly_rate INTO NEW.hourly_rate
    FROM hr_employees e
    JOIN pmo_resource_allocations a
      ON a.employee_id = e.id
     AND a.project_id = NEW.project_id
     AND a.status = 'active'
    WHERE e.user_id = NEW.user_id
    ORDER BY a.created_at DESC
    LIMIT 1;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_pmo_time_entry_rate
BEFORE INSERT ON public.pmo_time_entries
FOR EACH ROW EXECUTE FUNCTION public.pmo_time_entry_apply_rate();

CREATE POLICY "pmo_time_entries_select" ON "public"."pmo_time_entries"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND (
      "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
      OR ("user_id" = (select "auth"."uid"()))
    )
  );

CREATE POLICY "pmo_time_entries_insert" ON "public"."pmo_time_entries"
  FOR INSERT WITH CHECK (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND ("user_id" = (select "auth"."uid"()))
  );

CREATE POLICY "pmo_time_entries_update" ON "public"."pmo_time_entries"
  FOR UPDATE USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND (
      "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])
      OR ("user_id" = (select "auth"."uid"()))
    )
  ) WITH CHECK (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND (
      "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])
      OR ("user_id" = (select "auth"."uid"()))
    )
  );

CREATE POLICY "pmo_time_entries_delete" ON "public"."pmo_time_entries"
  FOR DELETE USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND (
      "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])
      OR ("user_id" = (select "auth"."uid"()))
    )
  );

-- ---------------------------------------------------------------------
-- Cost entries
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "public"."pmo_cost_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL REFERENCES "public"."tenants"("id") ON DELETE CASCADE,
    "project_id" "uuid" NOT NULL REFERENCES "public"."pmo_projects"("id") ON DELETE CASCADE,
    "entry_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "description" "text" NOT NULL,
    "category" "text" DEFAULT 'other'::"text" NOT NULL,
    "amount" "numeric"(14,2) NOT NULL,
    "reference_no" "text",
    "created_by" "uuid" REFERENCES "public"."app_users"("id"),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pmo_cost_entries_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "pmo_cost_entries_amount_check" CHECK (("amount" >= (0)::numeric)),
    CONSTRAINT "pmo_cost_entries_category_check" CHECK (("category" = ANY (ARRAY['materials'::"text", 'equipment'::"text", 'subcontractor'::"text", 'travel'::"text", 'labor'::"text", 'other'::"text"])))
);

ALTER TABLE "public"."pmo_cost_entries" OWNER TO "postgres";
ALTER TABLE "public"."pmo_cost_entries" ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS "pmo_cost_entries_project_idx"
  ON "public"."pmo_cost_entries" ("project_id", "entry_date");

CREATE POLICY "pmo_cost_entries_select" ON "public"."pmo_cost_entries"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

CREATE POLICY "pmo_cost_entries_insert" ON "public"."pmo_cost_entries"
  FOR INSERT WITH CHECK (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])
  );

CREATE POLICY "pmo_cost_entries_update" ON "public"."pmo_cost_entries"
  FOR UPDATE USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])
  ) WITH CHECK (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])
  );

CREATE POLICY "pmo_cost_entries_delete" ON "public"."pmo_cost_entries"
  FOR DELETE USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('pmo'::"text", ARRAY['admin'::"text", 'manager'::"text"])
  );

COMMENT ON TABLE "public"."pmo_time_entries" IS
  'Time logged by a user against a pmo project/task. hourly_rate is a point-in-time snapshot taken from the logger active resource allocation (trigger); NULL = uncosted hours.';
COMMENT ON TABLE "public"."pmo_cost_entries" IS
  'Direct project costs feeding Budget vs Actual. Writes are pmo admin/manager only.';

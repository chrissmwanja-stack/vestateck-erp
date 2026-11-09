-- Regulatory filings: transition workflow + audit trail + due dates.
--
-- Before: FilingsList.tsx let a legal admin/manager create a filing
-- already 'approved' (a status dropdown with all four states), and any
-- later filed/approved/rejected flip was a direct unlogged update. There
-- was no due_date to track against, and no history of who moved a filing
-- when. "Filings depth" per the audit roadmap.
--
-- Now:
--   1. law_regulatory_filings.due_date          -- the compliance date
--      being tracked (UG regulators: annual returns, tax deadlines...).
--
--   2. law_filing_events                        -- append-only audit rows
--      (status entered, actor, note, timestamp). RLS: legal module read;
--      writes only through transition_filing().
--
--   3. transition_filing(p_filing_id, p_status, p_note)
--      legal admin/manager only, enforcing a real state machine:
--        pending  -> filed | rejected
--        filed    -> approved | rejected
--        rejected -> pending            (re-open after fixing the cause)
--        approved -> (terminal)
--      Sets filing_date to today on -> filed when NULL. Every transition
--      appends a law_filing_events row.
--
-- Direct INSERT stays legal admin/manager (existing write tier), but new
-- filings are created 'pending' from the app and evolve only via
-- transition_filing().

ALTER TABLE "public"."law_regulatory_filings"
  ADD COLUMN IF NOT EXISTS "due_date" "date";

-- ---------------------------------------------------------------------
-- 1. Audit table
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "public"."law_filing_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL REFERENCES "public"."tenants"("id") ON DELETE CASCADE,
    "filing_id" "uuid" NOT NULL REFERENCES "public"."law_regulatory_filings"("id") ON DELETE CASCADE,
    "status" "text" NOT NULL,
    "actor_id" "uuid" NOT NULL REFERENCES "public"."app_users"("id"),
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "law_filing_events_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "law_filing_events_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'filed'::"text", 'approved'::"text", 'rejected'::"text"])))
);

ALTER TABLE "public"."law_filing_events" OWNER TO "postgres";
ALTER TABLE "public"."law_filing_events" ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS "law_filing_events_filing_idx"
  ON "public"."law_filing_events" ("filing_id", "created_at");

CREATE POLICY "law_filing_events_select" ON "public"."law_filing_events"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- ---------------------------------------------------------------------
-- 2. The state-machine RPC
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."transition_filing"("p_filing_id" "uuid", "p_status" "text", "p_note" "text" DEFAULT NULL)
RETURNS "public"."law_regulatory_filings"
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_filing public.law_regulatory_filings%rowtype;
  v_allowed boolean;
begin
  if not has_module_role('legal', array['admin', 'manager']) then
    raise exception 'not authorized: filing transitions require a legal admin or manager role';
  end if;

  select * into v_filing from law_regulatory_filings
  where id = p_filing_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'filing not found in this tenant';
  end if;

  v_allowed := (v_filing.status = 'pending'  and p_status in ('filed', 'rejected'))
            or (v_filing.status = 'filed'    and p_status in ('approved', 'rejected'))
            or (v_filing.status = 'rejected' and p_status = 'pending');

  if not v_allowed then
    raise exception 'invalid filing transition: % -> %', v_filing.status, p_status;
  end if;

  update law_regulatory_filings
  set status = p_status,
      filing_date = case when p_status = 'filed' and filing_date is null
                         then current_date else filing_date end
  where id = v_filing.id
  returning * into v_filing;

  insert into law_filing_events (tenant_id, filing_id, status, actor_id, note)
  values (v_filing.tenant_id, v_filing.id, p_status, auth.uid(), nullif(btrim(coalesce(p_note, '')), ''));

  return v_filing;
end;
$$;

ALTER FUNCTION "public"."transition_filing"("uuid", "text", "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."transition_filing"("uuid", "text", "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."transition_filing"("uuid", "text", "text") FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."transition_filing"("uuid", "text", "text") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."transition_filing"("uuid", "text", "text") TO "service_role";

COMMENT ON FUNCTION "public"."transition_filing"("uuid", "text", "text") IS
  'Moves a regulatory filing through pending -> filed -> approved/rejected (rejected may re-open to pending), appending a law_filing_events audit row. Legal admin/manager only. Sets filing_date on -> filed when missing.';

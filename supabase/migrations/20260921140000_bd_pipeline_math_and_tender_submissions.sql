-- Business Development: pipeline math + tender submission management
-- (roadmap P2, last piece). Before:
--   * weighted-pipeline math (value x probability) was re-implemented in
--     at least four screens (NewOpportunity, PipelineBoard,
--     PipelineReport, RevenueForecast) with no server-side guarantees --
--     a NULL probability from any writer made totals render NaN
--   * tender "submission" was a free Status select on TendersList doing a
--     direct UPDATE: open -> awarded if you liked, no submission record,
--     no reference number, no notification -- while a Submissions page
--     pretended to track them
--
-- This migration:
--   1. bd_opportunities probability guard trigger -- any insert/update
--      with probability NULL coalesces from the tenant's stage default
--      (bd_opportunity_stages.probability_default), so the weighted math
--      can never see a NULL again.
--   2. bd_pipeline_summary() -- the single server-side source of the
--      per-stage count/total/weighted math the reports share; honours
--      the tenant's own stage lookup (label/color/order, including
--      quiet stages), coalesces probabilities as the trigger does.
--   3. bd_tender_submissions -- one row per actual submission event
--      (portal/tracking reference, note, officer). Read-only via RLS;
--      written only through the transition RPC.
--   4. transition_tender() RPC -- the tender lifecycle as a state
--      machine: open -> submitted (writes the submission row) ->
--      under_evaluation -> awarded | lost; anything open-ish ->
--      cancelled. Award/loss/cancellation notify the tender's creator.

-- 1. Probability guard
CREATE OR REPLACE FUNCTION "public"."trg_bd_opportunity_probability"()
RETURNS trigger
LANGUAGE "plpgsql"
SET "search_path" TO 'public'
AS $$
begin
  if new.probability is null then
    select s.probability_default into new.probability
    from bd_opportunity_stages s
    where s.tenant_id = new.tenant_id
      and s.stage = new.stage
      and s.is_active;
    -- tenant without a seeded lookup: keep the pipeline math working
    new.probability := coalesce(new.probability, 10);
  end if;
  return new;
end;
$$;

DROP TRIGGER IF EXISTS "trg_bd_opportunity_probability" ON "public"."bd_opportunities";
CREATE TRIGGER "trg_bd_opportunity_probability"
BEFORE INSERT OR UPDATE ON "public"."bd_opportunities"
FOR EACH ROW EXECUTE FUNCTION "public"."trg_bd_opportunity_probability"();

-- 2. Shared pipeline math
CREATE OR REPLACE FUNCTION "public"."bd_pipeline_summary"()
RETURNS "jsonb"
LANGUAGE "sql" STABLE SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
  with params as (
    select get_my_tenant_id() as tenant_id
    where has_module_role('bd', array['admin', 'manager', 'member'])
  ), stages as (
    select s.stage, s.label, s.color, s.order_index, s.probability_default
    from bd_opportunity_stages s, params p
    where s.tenant_id = p.tenant_id and s.is_active
  ), opps as (
    select o.*
    from bd_opportunities o, params p
    where o.tenant_id = p.tenant_id
  ), agg as (
    select
      s.stage, s.label, s.color, s.order_index,
      count(o.id) as count,
      coalesce(sum(coalesce(o.estimated_value, 0)), 0) as total,
      coalesce(sum(coalesce(o.estimated_value, 0) * coalesce(o.probability, s.probability_default)::numeric / 100), 0) as weighted,
      case when count(o.id) = 0 then null
           else round(avg(coalesce(o.probability, s.probability_default)))
      end as avg_probability
    from stages s
    left join opps o on o.stage = s.stage
    group by s.stage, s.label, s.color, s.order_index
  )
  select jsonb_build_object(
    'stages', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'stage', a.stage, 'label', a.label, 'color', a.color,
          'order_index', a.order_index, 'count', a.count,
          'total', a.total, 'weighted', a.weighted,
          'avg_probability', a.avg_probability)
        order by a.order_index)
      from agg a), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'count', coalesce(sum(a.count), 0), 'total', coalesce(sum(a.total), 0),
        'weighted', coalesce(sum(a.weighted), 0))
      from agg a)
  )
$$;

ALTER FUNCTION "public"."bd_pipeline_summary"() OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."bd_pipeline_summary"() FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."bd_pipeline_summary"() FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."bd_pipeline_summary"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."bd_pipeline_summary"() TO "service_role";

COMMENT ON FUNCTION "public"."bd_pipeline_summary"() IS
  'Single server-side source of BD pipeline math: per tenant-defined stage (label/color/order honoured), count + total + weighted (value x probability, NULL probabilities coalesced to the stage default) + grand totals. bd module members only.';

-- 3. Submission event table
CREATE TABLE IF NOT EXISTS "public"."bd_tender_submissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL REFERENCES "public"."tenants"("id") ON DELETE CASCADE,
    "tender_id" "uuid" NOT NULL REFERENCES "public"."bd_tenders"("id") ON DELETE CASCADE,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "submitted_by" "uuid" NOT NULL REFERENCES "public"."app_users"("id"),
    "submission_ref" "text",
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bd_tender_submissions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "bd_tender_submissions_tender_unique" UNIQUE ("tender_id")
);

ALTER TABLE "public"."bd_tender_submissions" OWNER TO "postgres";
ALTER TABLE "public"."bd_tender_submissions" ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS "bd_tender_submissions_tender_idx"
  ON "public"."bd_tender_submissions" ("tender_id", "submitted_at");

CREATE POLICY "bd_tender_submissions_select" ON "public"."bd_tender_submissions"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('bd'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );
-- No insert/update/delete policies: submissions are written exclusively
-- by transition_tender(), so a submission can never be forged or edited.

-- 4. Tender lifecycle
CREATE OR REPLACE FUNCTION "public"."transition_tender"(
  "p_tender_id" "uuid",
  "p_status" "text",
  "p_ref" "text" DEFAULT NULL,
  "p_note" "text" DEFAULT NULL
)
RETURNS "public"."bd_tenders"
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_tender public.bd_tenders%rowtype;
  v_allowed boolean;
begin
  if not has_module_role('bd', array['admin', 'manager', 'member']) then
    raise exception 'not authorized: bd role required';
  end if;

  select * into v_tender from bd_tenders
  where id = p_tender_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'tender not found in this tenant';
  end if;

  v_allowed := (v_tender.status = 'open'             and p_status = 'submitted')
            or (v_tender.status = 'submitted'        and p_status in ('under_evaluation', 'awarded', 'lost', 'cancelled'))
            or (v_tender.status = 'under_evaluation' and p_status in ('awarded', 'lost', 'cancelled'))
            or (v_tender.status = 'open'             and p_status = 'cancelled');

  if not v_allowed then
    raise exception 'invalid tender transition: % -> %', v_tender.status, p_status;
  end if;

  update bd_tenders
  set status = p_status, updated_at = now()
  where id = v_tender.id
  returning * into v_tender;

  if p_status = 'submitted' then
    -- the submission event: portal/tracking reference + note, exactly
    -- once (unique tender_id -- a second submit is an invalid transition
    -- anyway since status is no longer 'open').
    insert into bd_tender_submissions (tenant_id, tender_id, submitted_by, submission_ref, note)
    values (v_tender.tenant_id, v_tender.id, auth.uid(),
            nullif(btrim(coalesce(p_ref, '')), ''),
            nullif(btrim(coalesce(p_note, '')), ''));
  end if;

  if p_status in ('awarded', 'lost', 'cancelled')
     and v_tender.created_by is not null
     and v_tender.created_by <> auth.uid() then
    insert into notifications (tenant_id, recipient_id, type, title, body)
    values (
      v_tender.tenant_id,
      v_tender.created_by,
      'tender_' || p_status,
      'Tender ' || p_status || ': ' || v_tender.title,
      format('Tender "%s" (%s) is now %s.%s',
        v_tender.title,
        coalesce(v_tender.tender_no, 'no number'),
        p_status,
        case when nullif(btrim(coalesce(p_note, '')), '') is not null
             then ' ' || btrim(p_note) else '' end)
    );
  end if;

  return v_tender;
end;
$$;

ALTER FUNCTION "public"."transition_tender"("uuid", "text", "text", "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."transition_tender"("uuid", "text", "text", "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."transition_tender"("uuid", "text", "text", "text") FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."transition_tender"("uuid", "text", "text", "text") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."transition_tender"("uuid", "text", "text", "text") TO "service_role";

COMMENT ON FUNCTION "public"."transition_tender"("uuid", "text", "text", "text") IS
  'Tender lifecycle: open -> submitted (writes bd_tender_submissions with the portal/tracking ref) -> under_evaluation -> awarded | lost; open/submitted/under_evaluation -> cancelled. Award/loss/cancellation notify the creator. bd members.';

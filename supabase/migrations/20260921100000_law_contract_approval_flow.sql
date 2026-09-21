-- Give Law & Compliance's contract approvals a real workflow. Previously:
-- ContractApprovals.tsx's Approve/Reject issued a direct
-- supabase.from('law_contracts').update({status: 'active'|'terminated'})
-- from the browser under legal admin/manager RLS. That meant:
--   * no audit trail -- who decided what, when and why lived nowhere
--   * no separation of duties -- the creator could approve their own draft
--   * "Reject" wrote status='terminated', which is semantically an
--     end-of-life state for contracts that WERE active; the check
--     constraint had no 'rejected' at all, and the notify trigger then
--     emailed the creator "Contract ... is now terminated" for a rejection
--   * drafts were approvable directly (no submit step); the queue listed
--     draft AND pending_approval rows as if they were the same thing
--
-- This migration adds the missing pieces, following the house conventions
-- (SECURITY DEFINER RPC writes like grant_hr_team_member /
-- create_payroll_run; audit tables like po_edits; the notify_* trigger
-- family from 2026-09-08):
--
--   1. law_contract_decisions  -- append-only audit trail
--      ('submitted' | 'approved' | 'rejected', actor, notes, timestamp).
--      RLS: tenant + legal module read; writes only through the RPCs below.
--
--   2. status enum gains 'rejected' (draft -> pending_approval ->
--      active | rejected; active -> expired | terminated stay as-is).
--
--   3. submit_contract_for_approval(p_contract_id)
--      draft -> pending_approval, records a 'submitted' decision row.
--      Any legal module role may submit (route tier).
--
--   4. decide_contract(p_contract_id, p_decision, p_notes)
--      pending_approval -> active ('approved') or rejected ('rejected'),
--      legal admin/manager ONLY, and never the contract's creator
--      (separation of duties). Rejection requires notes.
--
--   5. notify_contract_status_change() learns 'rejected' so creators get
--      told their contract was rejected (with the decision notes), instead
--      of a misleading "terminated" email -- and 'terminated' keeps its
--      original wording for genuine terminations.
--
-- Direct UPDATE on law_contracts stays permitted for legal admin/manager
-- (expired/terminated lifecycle management); the RPC path is how approval
-- decisions are meant to happen from now on.

-- ---------------------------------------------------------------------
-- 1. Audit table
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "public"."law_contract_decisions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL REFERENCES "public"."tenants"("id") ON DELETE CASCADE,
    "contract_id" "uuid" NOT NULL REFERENCES "public"."law_contracts"("id") ON DELETE CASCADE,
    "decision" "text" NOT NULL,
    "decided_by" "uuid" NOT NULL REFERENCES "public"."app_users"("id"),
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "law_contract_decisions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "law_contract_decisions_decision_check" CHECK (("decision" = ANY (ARRAY['submitted'::"text", 'approved'::"text", 'rejected'::"text"])))
);

ALTER TABLE "public"."law_contract_decisions" OWNER TO "postgres";
ALTER TABLE "public"."law_contract_decisions" ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS "law_contract_decisions_contract_idx"
  ON "public"."law_contract_decisions" ("contract_id", "created_at");

-- Read: legal module members (any tier) in their own tenant.
-- No INSERT/UPDATE/DELETE policies on purpose: rows are written solely by
-- the SECURITY DEFINER RPCs below (owner bypasses RLS, same convention as
-- every other RPC-only-write table in this schema).
CREATE POLICY "law_contract_decisions_select" ON "public"."law_contract_decisions"
  FOR SELECT USING (
    ("tenant_id" = "public"."get_my_tenant_id"())
    AND "public"."has_module_role"('legal'::"text", ARRAY['admin'::"text", 'manager'::"text", 'member'::"text"])
  );

-- ---------------------------------------------------------------------
-- 2. Allow 'rejected' as a contract status
-- ---------------------------------------------------------------------
ALTER TABLE "public"."law_contracts" DROP CONSTRAINT "law_contracts_status_check";
ALTER TABLE "public"."law_contracts" ADD CONSTRAINT "law_contracts_status_check"
  CHECK (("status" = ANY (ARRAY[
    'draft'::"text",
    'pending_approval'::"text",
    'active'::"text",
    'rejected'::"text",
    'expired'::"text",
    'terminated'::"text"
  ])));

-- ---------------------------------------------------------------------
-- 3. Submit a draft for approval
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."submit_contract_for_approval"("p_contract_id" "uuid")
RETURNS "public"."law_contracts"
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_contract public.law_contracts%rowtype;
begin
  if not has_module_role('legal', array['admin', 'manager', 'member']) then
    raise exception 'not authorized: legal module role required';
  end if;

  select * into v_contract from law_contracts
  where id = p_contract_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'contract not found in this tenant';
  end if;
  if v_contract.status <> 'draft' then
    raise exception 'only draft contracts can be submitted for approval (current status: %)', v_contract.status;
  end if;

  update law_contracts
  set status = 'pending_approval', updated_at = now()
  where id = v_contract.id
  returning * into v_contract;

  insert into law_contract_decisions (tenant_id, contract_id, decision, decided_by, notes)
  values (v_contract.tenant_id, v_contract.id, 'submitted', auth.uid(), null);

  return v_contract;
end;
$$;

ALTER FUNCTION "public"."submit_contract_for_approval"("uuid") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."submit_contract_for_approval"("uuid") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."submit_contract_for_approval"("uuid") FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."submit_contract_for_approval"("uuid") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."submit_contract_for_approval"("uuid") TO "service_role";

COMMENT ON FUNCTION "public"."submit_contract_for_approval"("uuid") IS
  'Moves a draft contract to pending_approval and records a submitted decision row. Any legal module role; same-tenant only.';

-- ---------------------------------------------------------------------
-- 4. Approve or reject a pending contract (admin/manager, not the creator)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."decide_contract"("p_contract_id" "uuid", "p_decision" "text", "p_notes" "text" DEFAULT NULL)
RETURNS "public"."law_contracts"
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_contract public.law_contracts%rowtype;
begin
  if not has_module_role('legal', array['admin', 'manager']) then
    raise exception 'not authorized: contract approval requires a legal admin or manager role';
  end if;

  if p_decision not in ('approved', 'rejected') then
    raise exception 'p_decision must be ''approved'' or ''rejected''';
  end if;

  if p_decision = 'rejected' and (p_notes is null or btrim(p_notes) = '') then
    raise exception 'rejection requires notes explaining why';
  end if;

  select * into v_contract from law_contracts
  where id = p_contract_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'contract not found in this tenant';
  end if;
  if v_contract.status <> 'pending_approval' then
    raise exception 'only contracts pending approval can be decided (current status: %)', v_contract.status;
  end if;

  -- Separation of duties: the person who drafted a contract must not be
  -- the one who approves it, even if they hold an approver role.
  if v_contract.created_by is not null and v_contract.created_by = auth.uid() then
    raise exception 'you cannot decide a contract you created -- another legal admin/manager must approve it';
  end if;

  update law_contracts
  set status = case p_decision when 'approved' then 'active' else 'rejected' end,
      updated_at = now()
  where id = v_contract.id
  returning * into v_contract;

  insert into law_contract_decisions (tenant_id, contract_id, decision, decided_by, notes)
  values (v_contract.tenant_id, v_contract.id, p_decision, auth.uid(), nullif(btrim(coalesce(p_notes, '')), ''));

  return v_contract;
end;
$$;

ALTER FUNCTION "public"."decide_contract"("uuid", "text", "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."decide_contract"("uuid", "text", "text") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."decide_contract"("uuid", "text", "text") FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."decide_contract"("uuid", "text", "text") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."decide_contract"("uuid", "text", "text") TO "service_role";

COMMENT ON FUNCTION "public"."decide_contract"("uuid", "text", "text") IS
  'Approves (active) or rejects a pending_approval contract with an audit row. Legal admin/manager only; creator may not self-approve; rejection requires notes.';

-- ---------------------------------------------------------------------
-- 5. Notifications: rejections deserve their own wording (and reason),
--    not a misleading "terminated" email. 'active' and genuine
--    'terminated' notifications keep their original behaviour.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_contract_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason text;
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('active', 'terminated', 'rejected')
     AND NEW.created_by IS NOT NULL THEN
    IF NEW.status = 'rejected' THEN
      -- attach the rejection notes, if a decision row was just written
      select d.notes into v_reason
      from law_contract_decisions d
      where d.contract_id = NEW.id and d.decision = 'rejected'
      order by d.created_at desc
      limit 1;
    END IF;
    INSERT INTO notifications (tenant_id, recipient_id, type, title, body)
    VALUES (
      NEW.tenant_id,
      NEW.created_by,
      'contract_' || NEW.status,
      (CASE NEW.status
         WHEN 'active'  THEN 'Contract approved: '
         WHEN 'rejected' THEN 'Contract rejected: '
         ELSE 'Contract terminated: ' END) || NEW.contract_no,
      CASE NEW.status
        WHEN 'active'  THEN format('Contract "%s" (%s) has been approved and is now active.', NEW.title, NEW.contract_no)
        WHEN 'rejected' THEN format('Contract "%s" (%s) was rejected.%s', NEW.title, NEW.contract_no,
                                coalesce(' Reason: ' || v_reason, ''))
        ELSE format('Contract "%s" (%s) is now terminated.', NEW.title, NEW.contract_no)
      END
    );
  END IF;
  RETURN NEW;
END;
$function$;

-- Trigger definition unchanged (it calls the function above).

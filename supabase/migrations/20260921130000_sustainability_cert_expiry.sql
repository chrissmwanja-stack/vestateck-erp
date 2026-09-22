-- Sustainability: certification expiry depth (roadmap P2.4).
-- Before: sustainability_certifications.status was hand-maintained --
-- 'valid'/'expired'/'pending_renewal' -- and nothing ever flipped it.
-- A cert could lapse for months; the list just rendered the stale chip.
--
-- This migration (same cronless-cron shape as
-- 20260921120000_machine_maintenance_workflow):
--   1. renewal_reminded_at marker column (sweep idempotency for the
--      30-day warning; the expired flip is transition-guarded by the
--      status change itself).
--   2. sustainability_cert_expiry_sweep() -- any module member can run
--      it (CertificationsList calls it on mount); it
--        a) flips 'valid' -> 'expired' for past-due certs (one-shot:
--           the flip can only happen once per cert) and notifies,
--        b) notifies about certs expiring within 30 days exactly once
--           (renewal_reminded_at), without touching their status --
--           renewal is a human decision, not a cron's.
--      Recipients: the cert's creator (when known) plus every
--      sustainability admin/manager of the tenant -- the people who
--      actually chase renewals. Outsiders get 0 and notify nobody.

ALTER TABLE "public"."sustainability_certifications"
  ADD COLUMN IF NOT EXISTS "renewal_reminded_at" timestamp with time zone;

CREATE OR REPLACE FUNCTION "public"."sustainability_cert_expiry_sweep"()
RETURNS integer
LANGUAGE "plpgsql" SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
declare
  v_cert record;
  v_count int := 0;
begin
  if not has_module_role('sustainability', array['admin', 'manager', 'member']) then
    return 0; -- outsiders just get nothing
  end if;

  -- (a) past-due valids lapse, once
  for v_cert in
    update sustainability_certifications
    set status = 'expired'
    where tenant_id = get_my_tenant_id()
      and status = 'valid'
      and expiry_date is not null
      and expiry_date < current_date
    returning id, tenant_id, name, standard, expiry_date, created_by
  loop
    insert into notifications (tenant_id, recipient_id, type, title, body)
    select distinct on (recipient) v_cert.tenant_id, recipient,
      'certification_expired',
      'Certification expired: ' || v_cert.name,
      format('Certification "%s"%s expired on %s. Status was set to expired.',
        v_cert.name,
        case when v_cert.standard is not null then ' (' || v_cert.standard || ')' else '' end,
        v_cert.expiry_date::text)
    from (
      values (v_cert.created_by::uuid)
      union
      select sr.user_id from staff_roles sr
      where sr.tenant_id = v_cert.tenant_id
        and sr.module = 'sustainability'
        and sr.role in ('admin', 'manager')
    ) as rec(recipient)
    where recipient is not null;

    v_count := v_count + 1;
  end loop;

  -- (b) renewals due within 30 days: remind admins once, keep status
  for v_cert in
    select id, tenant_id, name, standard, expiry_date, created_by
    from sustainability_certifications
    where tenant_id = get_my_tenant_id()
      and status = 'valid'
      and expiry_date is not null
      and expiry_date >= current_date
      and expiry_date <= current_date + 30
      and renewal_reminded_at is null
  loop
    insert into notifications (tenant_id, recipient_id, type, title, body)
    select distinct on (recipient) v_cert.tenant_id, recipient,
      'certification_expiring',
      'Certification expiring soon: ' || v_cert.name,
      format('Certification "%s"%s expires on %s (%s day(s) away). Consider renewal or set pending_renewal.',
        v_cert.name,
        case when v_cert.standard is not null then ' (' || v_cert.standard || ')' else '' end,
        v_cert.expiry_date::text, (v_cert.expiry_date - current_date)::text)
    from (
      values (v_cert.created_by::uuid)
      union
      select sr.user_id from staff_roles sr
      where sr.tenant_id = v_cert.tenant_id
        and sr.module = 'sustainability'
        and sr.role in ('admin', 'manager')
    ) as rec(recipient)
    where recipient is not null;

    update sustainability_certifications
    set renewal_reminded_at = now()
    where id = v_cert.id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

ALTER FUNCTION "public"."sustainability_cert_expiry_sweep"() OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."sustainability_cert_expiry_sweep"() FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."sustainability_cert_expiry_sweep"() FROM "anon";
GRANT EXECUTE ON FUNCTION "public"."sustainability_cert_expiry_sweep"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."sustainability_cert_expiry_sweep"() TO "service_role";

COMMENT ON FUNCTION "public"."sustainability_cert_expiry_sweep"() IS
  'Flips past-due certifications to expired (once) and reminds about renewals due within 30 days (once, via renewal_reminded_at); notifies the creator and sustainability admins/managers. Called by CertificationsList on mount. Returns the number of certifications newly flagged.';

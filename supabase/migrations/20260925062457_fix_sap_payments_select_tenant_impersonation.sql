-- sap_payments_select_tenant was the only SELECT policy in the schema
-- still doing its own inline tenant lookup instead of calling
-- get_my_tenant_id() -- so it never picked up the impersonation-aware
-- fallback that helper has (active platform-admin impersonation session,
-- else the caller's own tenant). Practical effect: a platform admin
-- impersonating a tenant could see every other tenant-scoped table but
-- this one. Bring it in line with every other tenant-scoped SELECT policy.
drop policy "sap_payments_select_tenant" on "public"."sap_payments";

create policy "sap_payments_select_tenant"
on "public"."sap_payments"
for select
using (tenant_id = get_my_tenant_id());
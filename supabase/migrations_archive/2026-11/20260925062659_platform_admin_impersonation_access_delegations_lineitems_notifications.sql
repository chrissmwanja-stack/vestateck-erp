-- Add platform-admin (while impersonating) access to three tables that
-- were scoped strictly to auth.uid() with no admin path at all, per the
-- "is platform admin a real super admin" audit:
--   - approval_delegations: view/revoke any tenant's delegations, to
--     unstick a stuck approval chain during support.
--   - request_line_items: add a line item to a request on a tenant's
--     behalf.
--   - notifications: read a user's notifications for support/debugging.
-- Scoped to is_platform_admin() AND tenant_id = get_my_tenant_id() --
-- i.e. only while actively impersonating that specific tenant, same as
-- every other tenant-scoped policy -- not an unconditional, always-on
-- cross-tenant bypass.

drop policy "approval_delegations_select_involved" on "public"."approval_delegations";
create policy "approval_delegations_select_involved"
on "public"."approval_delegations"
for select
using (
  (delegator_user_id = (select auth.uid()))
  or (delegate_user_id = (select auth.uid()))
  or (is_platform_admin() and tenant_id = get_my_tenant_id())
);

drop policy "approval_delegations_revoke_own" on "public"."approval_delegations";
create policy "approval_delegations_revoke_own"
on "public"."approval_delegations"
for update
using (
  ((delegator_user_id = (select auth.uid())) or (is_platform_admin() and tenant_id = get_my_tenant_id()))
  and status = 'active'
)
with check (
  ((delegator_user_id = (select auth.uid())) or (is_platform_admin() and tenant_id = get_my_tenant_id()))
  and status = 'revoked'
);

drop policy "request_line_items_insert" on "public"."request_line_items";
create policy "request_line_items_insert"
on "public"."request_line_items"
for insert
with check (
  exists (
    select 1 from requests r
    where r.id = request_line_items.request_id
      and (r.requester_id = (select auth.uid()) or (is_platform_admin() and r.tenant_id = get_my_tenant_id()))
  )
);

drop policy "notifications_select_own" on "public"."notifications";
create policy "notifications_select_own"
on "public"."notifications"
for select
using (
  (recipient_id = (select auth.uid()))
  or (is_platform_admin() and tenant_id = get_my_tenant_id())
);
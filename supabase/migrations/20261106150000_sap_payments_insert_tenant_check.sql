-- sap_payments: the INSERT policy only checked has_po_access(), with no tenant condition.
--
-- set_sap_payment_defaults() (BEFORE INSERT, SECURITY DEFINER) overwrites tenant_id
-- with the tenant of the purchase order named in the row, reading purchase_orders
-- past RLS. A caller with PO access in tenant A who supplied a purchase_order_id from
-- tenant B therefore produced a row stamped with tenant B's id, and the policy still
-- passed because it never looked at tenant_id. The row then showed up in tenant B's
-- payments list. Requires knowing a foreign purchase order id (UUIDs are not
-- guessable), so the practical risk was low, but it is a cross-tenant write.
--
-- Row-level security evaluates WITH CHECK after BEFORE ROW triggers, on the final
-- row, so checking tenant_id here sees the trigger-derived tenant. The UI sends the
-- caller's own tenant_id and a purchase order from the same tenant, so it is
-- unaffected.
--
-- ALTER POLICY, not DROP/CREATE: the policy is never absent. Idempotent.

alter policy sap_payments_insert_finance on public.sap_payments
  with check (has_po_access() and tenant_id = get_my_tenant_id());

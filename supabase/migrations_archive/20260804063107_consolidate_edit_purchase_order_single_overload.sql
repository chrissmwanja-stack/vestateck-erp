-- The previous migration left three overloads of edit_purchase_order
-- (4-arg, 7-arg, 10-arg) whose leading parameter names all match --
-- PostgREST calls RPCs with named notation, and Postgres can't pick a
-- "best candidate" between overloads that share a leading named subset,
-- so any call passing just the original 4 args (p_purchase_order_id,
-- p_vendor_name, p_amount, p_reason) -- which is every existing call
-- site today -- now fails with "function ... is not unique". Confirmed
-- by testing the exact call shape PurchaseOrders.tsx uses.
--
-- Fix: drop the two now-redundant overloads and keep a single function
-- with all optional fields trailing. Existing callers passing only the
-- first 4 named params keep working, since the extra 6 all default to
-- null and are no-ops in the body (coalesce'd against current values).
drop function public.edit_purchase_order(uuid, text, numeric, text);
drop function public.edit_purchase_order(uuid, text, numeric, text, text, text, date);

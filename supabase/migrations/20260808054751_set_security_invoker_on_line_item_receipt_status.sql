-- line_item_receipt_status was running with the view owner's privileges,
-- bypassing RLS on request_line_items and line_item_receipts (both RLS-enabled)
-- for any authenticated user querying it directly. No definer semantics are
-- needed here -- it's a plain read aggregation -- so switch to invoker mode
-- to match the codebase's v_* reporting view convention.
ALTER VIEW public.line_item_receipt_status SET (security_invoker = true);

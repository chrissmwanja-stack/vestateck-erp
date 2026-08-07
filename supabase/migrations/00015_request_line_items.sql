-- 20260801_request_line_items.sql
--
-- Adds multi-line-item support to `requests`, plus delivery_date and a
-- free-text subcontractor field. Does NOT touch item_description/quantity
-- on `requests` — those stay as a summary (description text, total
-- quantity across line items) since the approval queue / downstream RPCs
-- read them directly today. Full itemized detail lives in the new table.

ALTER TABLE requests
  ADD COLUMN IF NOT EXISTS delivery_date date,
  ADD COLUMN IF NOT EXISTS subcontractor text;

CREATE TABLE IF NOT EXISTS request_line_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
  material_service text NOT NULL,
  cost_code text,
  group_code text,
  place_of_use text,
  quantity numeric NOT NULL CHECK (quantity > 0),
  unit_price numeric CHECK (unit_price IS NULL OR unit_price >= 0),
  total numeric CHECK (total IS NULL OR total >= 0),
  currency text NOT NULL DEFAULT 'UGX',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_request_line_items_request ON request_line_items(request_id);

ALTER TABLE request_line_items ENABLE ROW LEVEL SECURITY;

-- Read access mirrors the parent request: the inner SELECT against
-- `requests` is itself subject to that table's own RLS policy for the
-- current session (this is NOT security definer), so a caller only sees
-- line items for requests they could already see.
CREATE POLICY request_line_items_select ON request_line_items
  FOR SELECT
  USING (EXISTS (SELECT 1 FROM requests r WHERE r.id = request_line_items.request_id));

-- Insert only allowed against a request the caller owns. Line items are
-- written in a second call right after the parent request insert (see
-- RequestSubmissionForm.tsx) — not wrapped in a single transaction/RPC,
-- so a failure between the two leaves an orphaned request with no line
-- items. Flagged in the open items list; a follow-up RPC
-- (submit_request_with_line_items) would close that gap properly.
CREATE POLICY request_line_items_insert ON request_line_items
  FOR INSERT
  WITH CHECK (EXISTS (SELECT 1 FROM requests r WHERE r.id = request_line_items.request_id AND r.requester_id = auth.uid()));

-- No UPDATE/DELETE policy: append-only, matching the requests/
-- invoice_requests pattern — corrections go through re-submission, not
-- editing a submitted request's line items in place.
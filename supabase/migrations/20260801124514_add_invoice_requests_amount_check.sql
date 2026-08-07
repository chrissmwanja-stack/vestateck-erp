ALTER TABLE invoice_requests
  ADD CONSTRAINT invoice_requests_amount_check CHECK (amount > 0);


-- Ensure the view enforces the querying user's RLS (not the view owner's),
-- and make sure authenticated clients can actually select from it.
alter view public.petty_cash_float_balances set (security_invoker = true);
grant select on public.petty_cash_float_balances to authenticated;

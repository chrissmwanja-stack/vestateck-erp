-- The raw INSERT into auth.users left several GoTrue-internal text columns
-- as NULL. GoTrue's Go driver scans these into plain (non-nullable)
-- strings, so NULL causes "error finding user: sql: Scan error ...
-- converting NULL to string is unsupported" on every login attempt.
-- Fix: backfill to empty string for the two users seeded in the previous
-- migration.

update auth.users
set
  email_change = coalesce(email_change, ''),
  email_change_token_new = coalesce(email_change_token_new, ''),
  email_change_token_current = coalesce(email_change_token_current, ''),
  phone_change = coalesce(phone_change, ''),
  phone_change_token = coalesce(phone_change_token, ''),
  reauthentication_token = coalesce(reauthentication_token, '')
where email in ('cce@test.local', 'procurement.offer@test.local');

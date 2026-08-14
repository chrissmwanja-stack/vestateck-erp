-- The null-string fix in 20260730144243_fix_seeded_users_null_string_columns.sql
-- only backfilled two users by email (cce@test.local, procurement.offer@test.local).
-- Every other test account was seeded with the same raw "insert into auth.users"
-- pattern (0001_init_core_schema.sql, 20260806143936_seed_it_hr_test_auth_users.sql,
-- 20260808143024_seed_pmo_and_machine_operation_test_users_and_lookups.sql) and has
-- the same gap: email_change, email_change_token_new, email_change_token_current,
-- phone_change, phone_change_token, and reauthentication_token are left NULL.
-- GoTrue's Go driver scans these into non-nullable strings, so NULL causes
-- "error finding user: sql: Scan error ... converting NULL to string is
-- unsupported" on every login attempt, surfaced to the client as a generic
-- "Database error querying schema" (unexpected_failure, 500).
--
-- Fix this for every row instead of enumerating emails, so it doesn't recur
-- the next time a test user is seeded via raw insert.

update auth.users
set
  email_change = coalesce(email_change, ''),
  email_change_token_new = coalesce(email_change_token_new, ''),
  email_change_token_current = coalesce(email_change_token_current, ''),
  phone_change = coalesce(phone_change, ''),
  phone_change_token = coalesce(phone_change_token, ''),
  reauthentication_token = coalesce(reauthentication_token, ''),
  confirmation_token = coalesce(confirmation_token, ''),
  recovery_token = coalesce(recovery_token, '')
where
  email_change is null
  or email_change_token_new is null
  or email_change_token_current is null
  or phone_change is null
  or phone_change_token is null
  or reauthentication_token is null
  or confirmation_token is null
  or recovery_token is null;
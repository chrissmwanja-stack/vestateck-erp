-- GoTrue's Go driver can't scan NULL into these auth.users text columns
-- (same class of bug as 20260730144243_fix_seeded_users_null_string_columns.sql
-- and 20260815051126_fix_all_seeded_users_null_string_columns.sql), causing
-- "error finding user: sql: Scan error on column index 8, name
-- 'email_change': converting NULL to string is unsupported" on password
-- login. Those two prior fixes missed email_change/email_change_token_new
-- specifically -- confirmed via direct query that exactly the 11
-- @test.local accounts have them NULL (0 non-test accounts affected).
update auth.users
set email_change = coalesce(email_change, ''),
    email_change_token_new = coalesce(email_change_token_new, '')
where email like '%@test.local'
  and (email_change is null or email_change_token_new is null);
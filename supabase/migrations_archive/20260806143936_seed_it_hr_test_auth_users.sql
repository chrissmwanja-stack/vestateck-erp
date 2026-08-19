-- Seeds the auth.users rows for the IT Manager and HR Manager test
-- accounts that 20260806143937_add_it_platform_admin_and_hr_manager.sql
-- inserts into app_users by fixed id. Those two auth.users rows were
-- created directly via the Supabase Studio Auth panel on 2026-08-06
-- (same session as the migration below, timestamp-adjacent) and never
-- captured in a migration. On a fresh replay this causes
-- app_users_id_fkey to fail -- the same class of pre-tracking gap as the
-- tenant/workflow_stages seed added to 0001_init_core_schema.sql, just
-- surfacing later in the history.
--
-- This file is already applied on the live DB and won't be re-run there;
-- this addition only affects fresh replays. Test password: Tester123

do $$
begin
  if not exists (select 1 from auth.users where id = 'c50dcbbf-78af-4582-b215-499f83ea47f0') then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token
    ) values
    ('00000000-0000-0000-0000-000000000000', 'c50dcbbf-78af-4582-b215-499f83ea47f0', 'authenticated', 'authenticated',
     'it@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-08-06 14:39:37.733784+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-08-06 14:39:37.733784+00', '2026-08-06 14:39:37.733784+00', '', ''),
    ('00000000-0000-0000-0000-000000000000', '53665127-5662-442b-bf63-92e930ff40ef', 'authenticated', 'authenticated',
     'hr@test.local', extensions.crypt('Tester123', extensions.gen_salt('bf')),
     '2026-08-06 14:39:37.733784+00', '{"provider":"email","providers":["email"]}', '{}',
     '2026-08-06 14:39:37.733784+00', '2026-08-06 14:39:37.733784+00', '', '');
  end if;
end $$;
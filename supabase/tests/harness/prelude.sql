-- Minimal Supabase-shaped environment for PGlite (real PostgreSQL, WASM).
-- Only what the migrations and tests actually touch. Every shim is marked SHIM so a reviewer
-- can see exactly how far this harness is from production.
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;

create schema if not exists extensions;
create schema if not exists auth;
create schema if not exists storage;
create schema if not exists supabase_migrations;
create schema if not exists cron;
create schema if not exists realtime;
create schema if not exists vault;

grant usage on schema public to anon, authenticated, service_role;

-- SHIM: btree_gist is unavailable in this build. Its only use in the baseline is a gist
-- EXCLUDE constraint over btree columns, which a stub operator class cannot satisfy. Creating
-- the extension as a no-op succeeds; the one constraint that needs it is handled below by the
-- baseline load, which records the failure rather than hiding it.
create or replace function extensions.uuid_generate_v4() returns uuid language sql as $$ select gen_random_uuid() $$;
create or replace function public.uuid_generate_v4() returns uuid language sql as $$ select gen_random_uuid() $$;
-- SHIM: pgcrypto's crypt/gen_salt, used by test fixtures that seed auth.users with a password.
-- Any stored value works: nothing in these tests authenticates. Reported as a shim.
create or replace function extensions.gen_salt(p_type text default 'bf') returns text language sql as $$ select '$2a$06$fixturefixturefixturefi' $$;
create or replace function extensions.crypt(p_password text, p_salt text) returns text language sql as $$ select '$2a$06$fixturefixturefixturefi' $$;
create or replace function public.gen_salt(p_type text default 'bf') returns text language sql as $$ select extensions.gen_salt(p_type) $$;
create or replace function public.crypt(p_password text, p_salt text) returns text language sql as $$ select extensions.crypt(p_password, p_salt) $$;

-- SHIM: auth.uid()/auth.role()/auth.jwt() read the same GUC the tests set.
-- nullif BEFORE the cast, exactly as the real auth.uid() does it. A custom GUC that has been
-- set and then rolled back reverts to the empty string, not to NULL -- so a test file run in a
-- session that an earlier file already used left request.jwt.claims = '' and every call raised
-- 22P02 'invalid input syntax for type json'. That is a harness defect, not a product one, and
-- it only appeared when several test files shared a session.
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', current_user)
$$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;

-- SHIM: the parts of the auth schema the migrations and tests reference.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  aud text, role text, email text, encrypted_password text,
  email_confirmed_at timestamptz, raw_app_meta_data jsonb, raw_user_meta_data jsonb,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  last_sign_in_at timestamptz, banned_until timestamptz
);
-- The four columns below are in real Supabase's auth.users and are referenced by test files
-- that seed users directly (instance_id, password/confirmation/recovery bookkeeping). Without
-- them those files fail at their fixtures with 42703 -- a harness gap, not a product defect.
alter table auth.users add column if not exists instance_id uuid;
alter table auth.users add column if not exists encrypted_password text;
alter table auth.users add column if not exists email_confirmed_at timestamptz;
alter table auth.users add column if not exists confirmation_token text;
alter table auth.users add column if not exists recovery_token text;

create table if not exists auth.mfa_factors (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  friendly_name text, factor_type text, status text,
  created_at timestamptz default now(), updated_at timestamptz default now()
);

-- SHIM: pg_cron is unavailable.
create or replace function cron.schedule(p_name text, p_schedule text, p_command text)
returns bigint language sql as $$ select 1::bigint $$;
create or replace function cron.schedule(p_schedule text, p_command text)
returns bigint language sql as $$ select 1::bigint $$;
create or replace function cron.unschedule(p_name text) returns boolean language sql as $$ select true $$;
create or replace function cron.unschedule(p_jobid bigint) returns boolean language sql as $$ select true $$;


-- SHIM: the parts of the Supabase storage schema these migrations reference.
create table if not exists storage.buckets (
  id text primary key, name text, owner uuid, created_at timestamptz default now(),
  updated_at timestamptz default now(), public boolean default false, avif_autodetection boolean,
  file_size_limit bigint, allowed_mime_types text[]
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text, owner uuid, created_at timestamptz default now(),
  updated_at timestamptz default now(), last_accessed_at timestamptz default now(),
  metadata jsonb, path_tokens text[]
);
-- storage.foldername(name) returns the path parts; the tenant is the first one.
create or replace function storage.foldername(p_name text) returns text[] language sql immutable as $$
  select (string_to_array(p_name, '/'))[1:greatest(array_length(string_to_array(p_name, '/'), 1) - 1, 1)]
$$;

-- SHIM: pg_cron is unavailable, but migrations both query cron.job and (RC-9) schedule a job,
-- so the schema has to exist as ordinary tables. These are not pg_cron: nothing runs on a timer.
create table if not exists cron.job (
  jobid bigserial primary key,
  jobname text unique,
  schedule text,
  command text,
  active boolean default true
);
create table if not exists cron.job_run_details (
  jobid bigint,
  status text,
  start_time timestamptz,
  end_time timestamptz,
  return_message text
);
create or replace function cron.schedule(p_name text, p_schedule text, p_command text)
returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command) values (p_name, p_schedule, p_command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid
$$;
create or replace function cron.schedule(p_schedule text, p_command text)
returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command)
  values ('job_' || nextval('cron.job_jobid_seq')::text, p_schedule, p_command) returning jobid
$$;
create or replace function cron.unschedule(p_name text) returns boolean language sql as $$
  delete from cron.job where jobname = p_name; select true
$$;
create or replace function cron.unschedule(p_jobid bigint) returns boolean language sql as $$
  delete from cron.job where jobid = p_jobid; select true
$$;

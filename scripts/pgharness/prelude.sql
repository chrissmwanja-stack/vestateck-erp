-- =====================================================================
-- Supabase-shaped prelude for replaying this repo's migrations into a
-- plain PostgreSQL cluster (no Supabase stack, no Docker).
--
-- Prepared after the real project's catalog: the roles, the auth/storage
-- schemas and helpers the migrations call, and pg_cron stubs (the extension
-- itself is unavailable, and the baseline only needs schedule/unschedule).
--
-- Usage: see build.sh in this directory.
-- =====================================================================

-- --- roles -----------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then
    create role supabase_admin login superuser;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    create role supabase_auth_admin login noinherit createrole;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_storage_admin') then
    create role supabase_storage_admin login noinherit createrole;
  end if;
end $$;

grant anon, authenticated, service_role to authenticator;

-- --- schemas ---------------------------------------------------------
create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;
create schema if not exists cron;
grant usage on schema extensions to public;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema storage to anon, authenticated, service_role;

-- --- extensions ------------------------------------------------------
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists btree_gist with schema extensions;

-- --- auth ------------------------------------------------------------
create table if not exists auth.users (
  instance_id             uuid,
  id                      uuid primary key,
  aud                     text,
  role                    text,
  email                   text,
  encrypted_password      text,
  email_confirmed_at      timestamptz,
  invited_at              timestamptz,
  confirmation_token      text,
  confirmation_sent_at    timestamptz,
  recovery_token          text,
  recovery_sent_at        timestamptz,
  email_change_token_new  text,
  email_change            text,
  email_change_sent_at    timestamptz,
  last_sign_in_at         timestamptz,
  raw_app_meta_data       jsonb,
  raw_user_meta_data      jsonb,
  is_super_admin          boolean,
  created_at              timestamptz,
  updated_at              timestamptz,
  phone                   text,
  phone_confirmed_at      timestamptz,
  phone_change            text default '',
  phone_change_token      text default '',
  phone_change_sent_at    timestamptz,
  email_change_token_current text default '',
  email_change_confirm_status smallint default 0,
  banned_until            timestamptz,
  reauthentication_token  text default '',
  reauthentication_sent_at timestamptz,
  is_sso_user             boolean not null default false,
  is_anonymous            boolean not null default false,
  deleted_at              timestamptz
);

create table if not exists auth.mfa_factors (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  friendly_name   text,
  factor_type     text not null,
  status          text not null,
  secret          text,
  phone           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  last_challenged_at timestamptz
);

create table if not exists auth.identities (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  identity_data   jsonb not null,
  provider        text not null,
  provider_id     text,
  last_sign_in_at timestamptz,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  email           text
);

grant all on all tables in schema auth to anon, authenticated, service_role;

-- The helpers the app's RLS and functions call.
create or replace function auth.jwt() returns jsonb
language sql stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$;

create or replace function auth.uid() returns uuid
language sql stable
as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid;
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select nullif(auth.jwt() ->> 'role', '')::text;
$$;

create or replace function auth.email() returns text
language sql stable
as $$
  select nullif(auth.jwt() ->> 'email', '')::text;
$$;

-- --- storage ---------------------------------------------------------
create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  owner              uuid,
  owner_id           text,
  public             boolean default false,
  avif_autodetection boolean default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);

create table if not exists storage.objects (
  id               uuid primary key default gen_random_uuid(),
  bucket_id        text references storage.buckets(id),
  name             text,
  owner            uuid,
  owner_id         text,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata         jsonb,
  path_tokens      text[] generated always as (string_to_array(name, '/')) stored,
  version          text
);

grant all on all tables in schema storage to anon, authenticated, service_role;

-- Supabase ships storage with RLS already on; the app's own policies on
-- storage.objects (po_documents_tenant_*, documents_*) assume that.
alter table storage.buckets enable row level security;
alter table storage.objects enable row level security;

create or replace function storage.foldername(p_name text) returns text[]
language plpgsql immutable
as $$
declare
  parts text[];
begin
  parts := string_to_array(p_name, '/');
  return parts[1:array_length(parts, 1) - 1];
end $$;

-- --- pg_cron stand-in ------------------------------------------------
-- The baseline schedules one job; the extension is not installable here.
create table if not exists cron.job (
  jobid bigserial primary key,
  jobname text,
  schedule text,
  command text,
  nodename text,
  nodeport integer
);

create or replace function cron.schedule(p_name text, p_sched text, p_cmd text)
returns bigint language sql as $$ select 1::bigint $$;

create or replace function cron.unschedule(p_jobid bigint)
returns boolean language sql as $$ select true $$;

create or replace function cron.unschedule(p_name text)
returns boolean language sql as $$ select true $$;

-- Singleton settings table backing the /admin/settings screen.
-- "id boolean primary key default true" + check constraint guarantees
-- exactly one row ever exists.
--
-- Applied 2026-08-19 (version 20260819062321).

create table if not exists public.platform_settings (
  id boolean primary key default true,
  branding jsonb not null default '{}'::jsonb,
  notifications jsonb not null default '{}'::jsonb,
  security jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  constraint platform_settings_singleton check (id)
);

insert into public.platform_settings (id) values (true)
on conflict (id) do nothing;

alter table public.platform_settings enable row level security;

-- Matches the existing is_platform_admin() SQL function (SECURITY
-- DEFINER, reads app_users.is_platform_admin for auth.uid()) used
-- throughout the rest of the platform-admin RPCs -- not a bespoke
-- check invented for this table.
create policy "platform_settings_select_admin"
  on public.platform_settings
  for select
  using (is_platform_admin());

create policy "platform_settings_update_admin"
  on public.platform_settings
  for update
  using (is_platform_admin())
  with check (is_platform_admin());

-- Example shape for each jsonb column, so the frontend types line up:
--
-- branding:
--   { "platform_name": "VestaPortal", "logo_url": "...", "primary_color": "#1976d2" }
--
-- notifications:
--   { "alert_recipients": ["admin@vestateck.com"], "pending_company_threshold_days": 2 }
--
-- security:
--   { "session_timeout_minutes": 60, "require_mfa": false }
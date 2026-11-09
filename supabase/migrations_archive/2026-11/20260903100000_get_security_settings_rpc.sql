-- Backs the P0.5 MFA/session-timeout fix. platform_settings RLS is
-- platform-admin-only (platform_settings_select_admin), which is
-- correct for the branding/notifications columns but meant every
-- ordinary user's client -- AuthProvider's idle-timeout check,
-- RequireAuth's MFA-enforcement check -- got 0 rows and silently fell
-- back to the frontend's hardcoded defaults. That's exactly how
-- P0.5 ended up a placebo: even a wired-up client couldn't read the
-- setting it needed to enforce.
--
-- SECURITY DEFINER, but scoped to returning only the two security
-- fields (not branding/notifications, which have no reason to bypass
-- RLS) -- every authenticated user needs these two to enforce their
-- own session locally, but still can't write platform_settings or
-- read the rest of the row.
create or replace function public.get_security_settings()
returns table (session_timeout_minutes integer, require_mfa boolean)
language sql
security definer
set search_path = public
as $$
  select
    coalesce((select (security ->> 'session_timeout_minutes')::integer from platform_settings where id = true), 60),
    coalesce((select (security ->> 'require_mfa')::boolean from platform_settings where id = true), false);
$$;

grant execute on function public.get_security_settings() to authenticated;
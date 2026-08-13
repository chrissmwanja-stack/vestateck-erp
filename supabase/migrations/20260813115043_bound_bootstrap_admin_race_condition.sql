-- Security fix: close the bootstrap-admin race condition flagged in the
-- reconstructed bootstrap_platform_admin migration notes.
--
-- bootstrap-admin/index.ts currently does a count-check ("does any
-- platform admin exist?") then an insert/update, with no transactional
-- guard between the two. Two concurrent requests, both bearing a valid
-- BOOTSTRAP_ADMIN_CODE, arriving before either has committed, could both
-- pass the count-check and both end up as platform admins.
--
-- Fix: a partial unique index on app_users(is_platform_admin) restricted
-- to true rows. Postgres allows unlimited rows where the predicate is
-- false, but only one row can ever satisfy is_platform_admin = true.
-- A second concurrent claim now fails at the database level with a
-- unique_violation (23505), regardless of what the application-level
-- count-check saw a moment earlier.

create unique index app_users_single_platform_admin
  on public.app_users (is_platform_admin)
  where is_platform_admin = true;
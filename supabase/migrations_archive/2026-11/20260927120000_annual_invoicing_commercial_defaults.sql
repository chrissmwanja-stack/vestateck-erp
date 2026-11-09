-- Annual-invoice commercial model: stop defaulting new tenants into a
-- self-serve "trial" that this product doesn't actually offer.
--
-- Background: tenants.plan/subscription_status were added by
-- 20260922180000_tenant_profile_and_subscription.sql, explicitly
-- documented as informational -- the platform operator decides whether
-- to set read_only or suspend, nothing reads these to gate access. That
-- part is correct and unchanged by this migration: tenants.status
-- (active/pending/suspended) and tenants.read_only remain the only two
-- levers that actually control access, both set manually by a platform
-- admin via set_tenant_status()/set_tenant_read_only(), both audited.
--
-- What was wrong: the *defaults*. plan defaulted to 'trial' and
-- subscription_status to 'trialing', and create-tenant never overrode
-- them -- so every company onboarded (there is no self-serve signup;
-- onboarding-invite-only company creation is already an admin action
-- for a company that pays annually) started life silently mislabeled
-- as an evaluation trial until someone remembered to fix it by hand on
-- the Company Detail screen.
--
-- This migration:
--   1. Changes the column defaults to plan='standard',
--      subscription_status='active' (annual-invoice, paid, in good
--      standing -- the normal state for a real customer).
--   2. Backfills the two live non-internal tenants that are still
--      sitting on the old accidental defaults with no actual trial in
--      progress (trial_ends_at was never set for either).
--   3. Leaves 'trial'/'trialing' as valid, selectable values -- Company
--      Detail's own per-tenant editor keeps them for the rare case an
--      operator genuinely wants to flag a prospect as evaluating before
--      signing -- they're just no longer what a new company gets by
--      accident.
--
-- Not touched here (deliberately, to keep this change small and low
-- risk): the create-tenant edge function now sets plan/subscription_status
-- explicitly on insert (see supabase/functions/create-tenant), so these
-- new defaults are a safety net, not the primary mechanism. The
-- operator-only reporting surfaces that reference trial_ends_at
-- (Company Detail's trial-ends alert, the weekly operator digest's
-- "trials ending" section, the onboarding dashboard's trial funnel
-- card) are left in place -- they simply stay empty/dormant now that
-- nothing sets trial_ends_at by default, exactly like read_only does
-- when unused. Only the cross-company "manage my trial funnel" surfaces
-- that don't fit this business model were removed, in the app code
-- alongside this migration: the customer-facing trial banner, and the
-- Companies console's global "Subscription: Trialing" / "Needs
-- attention: Trial ending" filters.

alter table public.tenants
  alter column plan set default 'standard',
  alter column subscription_status set default 'active';

comment on column public.tenants.plan is
  'Commercial plan as recorded by the platform operator. ''internal'' is for the platform-admin home tenant only. Defaults to ''standard'' -- this platform has no self-serve trial, so ''trial'' is only ever set manually for a genuine pre-contract evaluation.';
comment on column public.tenants.subscription_status is
  'active | past_due | cancelled | trialing. Informational -- the operator decides whether to set read_only or suspend; nothing reads this to gate access. Defaults to ''active'' (paid, annual invoice, in good standing). ''trialing'' is available for a manually-flagged pre-contract evaluation but is never the default.';

-- Backfill: the only two non-internal tenants live today are still on
-- the old accidental defaults with no trial actually in progress.
update public.tenants
set plan = 'standard',
    subscription_status = 'active'
where plan = 'trial'
  and subscription_status = 'trialing'
  and trial_ends_at is null;

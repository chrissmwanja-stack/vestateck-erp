// Split into apps/web/src/features/admin/company-detail/ (types, constants,
// utils, the data/mutation hook, and one file per tab) -- this file stays
// as a re-export so existing imports (`./CompanyDetail`) keep working.
export { default, buildProfilePatch, daysUntil, actionLabel, PLAN_OPTIONS, SUBSCRIPTION_OPTIONS } from './company-detail/components/Index';
-- Supabase's performance advisor flagged two foreign keys without a
-- covering index (unindexed_foreign_keys, INFO level):
--   platform_settings.updated_by -> app_users(id)
--   tenant_modules.enabled_by    -> app_users(id)
-- Adding covering indexes closes both findings.
CREATE INDEX IF NOT EXISTS idx_platform_settings_updated_by ON public.platform_settings (updated_by);
CREATE INDEX IF NOT EXISTS idx_tenant_modules_enabled_by ON public.tenant_modules (enabled_by);
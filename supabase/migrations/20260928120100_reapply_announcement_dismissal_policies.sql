-- Reconcile live RLS with what 20260925133000 intended for
-- platform_announcement_dismissals.
--
-- 20260925133000 is recorded as applied, but the live policies still use
-- bare auth.uid() (re-evaluated per row; flagged by the performance
-- advisor as auth_rls_initplan) and the delete-own policy it defines does
-- not exist live. The migration was edited after it was applied (commit
-- 0a55dcb corrected a copy-pasted tenant_id predicate), so production kept
-- the older state while schema_migrations still listed it as done.
--
-- Checked live before writing this: these two are the ONLY public policies
-- still using bare auth.uid(); every other policy that migration touched
-- is already in the (select auth.uid()) form.
--
-- The table is platform-wide (announcement_id, user_id) with no tenant_id.

drop policy if exists "platform_announcement_dismissals_select_own" on public.platform_announcement_dismissals;
create policy "platform_announcement_dismissals_select_own" on public.platform_announcement_dismissals
  for select using (user_id = (select auth.uid()));

drop policy if exists "platform_announcement_dismissals_insert_own" on public.platform_announcement_dismissals;
create policy "platform_announcement_dismissals_insert_own" on public.platform_announcement_dismissals
  for insert with check (user_id = (select auth.uid()));

drop policy if exists "platform_announcement_dismissals_delete_own" on public.platform_announcement_dismissals;
create policy "platform_announcement_dismissals_delete_own" on public.platform_announcement_dismissals
  for delete using (user_id = (select auth.uid()));

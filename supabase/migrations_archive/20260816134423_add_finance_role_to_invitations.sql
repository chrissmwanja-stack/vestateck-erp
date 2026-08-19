-- Wires finance_team_members into the invite flow. Until now there was no
-- path to populate finance_team_members at all -- it's been empty since
-- the one test row from seed_test_finance_officer was swept by a cleanup
-- migration, meaning is_finance_team_member() only ever passed for
-- platform admins. Mirrors the modules_and_roles pattern already used for
-- staff_roles: null on the invitations row for company_admin (implies
-- full 'finance' access, matching how modules_and_roles=null implies all
-- 8 modules as admin), explicit value for member invites.
alter table public.invitations
  add column finance_role text
    check (finance_role in ('finance', 'cost_control'));

comment on column public.invitations.finance_role is
  'Grants a finance_team_members row on accept. NULL for company_admin invites (implies ''finance'' automatically, same as modules_and_roles=null implying all 8 modules). For member invites: ''finance'' (view+write) or ''cost_control'' (view only), or NULL for no finance access.';
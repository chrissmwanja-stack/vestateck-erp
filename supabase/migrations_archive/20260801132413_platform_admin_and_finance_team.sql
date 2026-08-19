-- Temporary, minimal admin concept: a single cross-tenant flag on
-- app_users. Full role/permission management (tenant admin vs platform
-- super admin, self-service allocation of rights) is deferred -- this is
-- just enough to gate who can manage Finance team membership for now.
ALTER TABLE app_users ADD COLUMN is_platform_admin boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION is_platform_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT COALESCE((SELECT is_platform_admin FROM app_users WHERE id = auth.uid()), false);
$$;

-- Finance / Cost Control team membership, per tenant. Deliberately
-- separate from the approval_assignments / has_po_access() workflow-stage
-- system -- "is part of Finance" and "is assigned to a PO-generating
-- approval stage" are different facts that shouldn't be conflated.
CREATE TABLE finance_team_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('finance', 'cost_control')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, user_id, role)
);

ALTER TABLE finance_team_members ENABLE ROW LEVEL SECURITY;

-- Matches the conservative pattern already used on approval_assignments:
-- people see their own membership row, admins see everything (needed for
-- the management UI).
CREATE POLICY finance_team_members_select_own_or_admin
  ON finance_team_members FOR SELECT
  USING (user_id = auth.uid() OR is_platform_admin());

CREATE POLICY finance_team_members_insert_admin
  ON finance_team_members FOR INSERT
  WITH CHECK (is_platform_admin());

CREATE POLICY finance_team_members_update_admin
  ON finance_team_members FOR UPDATE
  USING (is_platform_admin())
  WITH CHECK (is_platform_admin());

CREATE POLICY finance_team_members_delete_admin
  ON finance_team_members FOR DELETE
  USING (is_platform_admin());

-- Helper for future finance-module screens. p_role NULL means "any
-- finance-team role counts"; pass 'finance' or 'cost_control' to check a
-- specific one.
CREATE OR REPLACE FUNCTION is_finance_team_member(p_role text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM finance_team_members
    WHERE user_id = auth.uid()
      AND tenant_id = get_my_tenant_id()
      AND (p_role IS NULL OR role = p_role)
  );
$$;

GRANT EXECUTE ON FUNCTION is_platform_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION is_finance_team_member(text) TO authenticated;

-- Flag the initial admin.
UPDATE app_users SET is_platform_admin = true WHERE email = 'gm@test.local';

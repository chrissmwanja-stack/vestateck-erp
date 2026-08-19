CREATE OR REPLACE FUNCTION public.is_finance_team_member(p_role text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT
    is_platform_admin()
    OR EXISTS (
      SELECT 1 FROM finance_team_members
      WHERE user_id = auth.uid()
        AND tenant_id = get_my_tenant_id()
        AND (p_role IS NULL OR role = p_role)
    );
$function$;

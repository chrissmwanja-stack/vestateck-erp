-- law_compliance_register had SELECT/INSERT/UPDATE policies but no
-- DELETE policy. With RLS enabled and no DELETE policy, Postgres
-- denies all deletes by default -- including for legal admins.
-- Match the role gate already used on INSERT (legal admin/manager),
-- consistent with the sibling law_cases_delete / law_contracts_delete
-- policies elsewhere in the schema.

CREATE POLICY law_compliance_delete ON public.law_compliance_register
FOR DELETE USING (
  (tenant_id = get_my_tenant_id())
  AND has_module_role('legal', ARRAY['admin', 'manager'])
);
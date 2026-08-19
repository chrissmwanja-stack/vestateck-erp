-- material_catalog had no uniqueness guard on (tenant_id, code), unlike
-- its sibling lookup tables material_types and material_groups. This
-- allowed duplicate material codes per tenant and made the sample-data
-- seed migration (20260814090557) unsafe to replay. Bring it in line.

alter table material_catalog
  add constraint material_catalog_tenant_id_code_key unique (tenant_id, code);
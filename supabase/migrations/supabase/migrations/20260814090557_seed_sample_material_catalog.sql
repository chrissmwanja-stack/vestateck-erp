-- Sample material master data for the Test Company tenant, so the New
-- Request line-item entry has something to pick from during procurement
-- testing. material_catalog/material_types/material_groups were schema-
-- ready but completely empty (0 rows) -- this was blocking material
-- selection entirely, independent of the RLS/grant fixes done earlier
-- today.
--
-- material_types/material_groups have a BEFORE INSERT trigger
-- (set_material_lookup_defaults) that overwrites tenant_id with
-- get_my_tenant_id(), which relies on auth.uid() from a real logged-in
-- session -- there is none in a migration context, so it raises. Safe to
-- disable just for this seed insert, since we're supplying tenant_id
-- explicitly and correctly, and re-enable immediately after so the
-- normal app-side insert path (real users, real sessions) is unaffected.

alter table material_types disable trigger trg_set_material_types_defaults;
alter table material_groups disable trigger trg_set_material_groups_defaults;

do $$
declare
  v_tenant_id uuid := 'c4206048-d594-447d-a0c9-c8a103302e56'; -- Test Company
  v_type_consumable uuid;
  v_type_equipment uuid;
  v_group_it uuid;
  v_group_office uuid;
begin
  insert into material_types (tenant_id, code, name) values
    (v_tenant_id, 'CONS', 'Consumable')
    returning id into v_type_consumable;
  insert into material_types (tenant_id, code, name) values
    (v_tenant_id, 'EQUIP', 'Equipment')
    returning id into v_type_equipment;

  insert into material_groups (tenant_id, code, name) values
    (v_tenant_id, 'ITS', 'IT Supplies')
    returning id into v_group_it;
  insert into material_groups (tenant_id, code, name) values
    (v_tenant_id, 'OFC', 'Office Supplies')
    returning id into v_group_office;

  insert into material_catalog (tenant_id, code, name, unit, material_type_id, material_group_id) values
    (v_tenant_id, 'MAT-0001', 'Toner Cartridge - HP 26A', 'Piece', v_type_consumable, v_group_it),
    (v_tenant_id, 'MAT-0002', 'Toner Cartridge - Canon 337', 'Piece', v_type_consumable, v_group_it),
    (v_tenant_id, 'MAT-0003', 'A4 Paper Ream (80gsm)', 'Ream', v_type_consumable, v_group_office),
    (v_tenant_id, 'MAT-0004', 'USB Flash Drive 32GB', 'Piece', v_type_consumable, v_group_it),
    (v_tenant_id, 'MAT-0005', 'External Hard Drive 1TB', 'Piece', v_type_equipment, v_group_it),
    (v_tenant_id, 'MAT-0006', 'Office Chair - Ergonomic', 'Piece', v_type_equipment, v_group_office);
end $$;

alter table material_types enable trigger trg_set_material_types_defaults;
alter table material_groups enable trigger trg_set_material_groups_defaults;
-- Seed a handful of request_line_items so Request Tracking's Cost Code /
-- Place of use filters have something real to match against. Real,
-- permanent rows (not part of a rolled-back test transaction) tied to
-- existing seeded requests (MR-00001 through MR-00008).
--
-- MR-00001 through MR-00008 and the "Uganda Project Site" cost center they
-- reference were created through normal app use before migration tracking
-- caught up (same class of issue as the tenant/workflow_stages seed data --
-- see the reconstructed migrations from the drift-reconciliation pass).
-- No local migration ever created them, so a fresh shadow replay has no
-- parent rows for this file's request_line_items insert to reference.
-- Backfilling both here, pulled directly from the live project, so replay
-- has real parents instead of hitting a FK violation.
--
-- Both requests and cost_centers have a BEFORE INSERT trigger that
-- overwrites tenant_id (and, for requests, requester_id/department_id/
-- current_stage_id/status/created_at/updated_at) from auth.uid(), which
-- isn't set in a migration context. Bypassing both triggers for these
-- inserts only, same pattern already used for departments in
-- 20260805090723_bd_module_schema.sql.

alter table cost_centers disable trigger trg_set_cost_center_defaults;

insert into cost_centers (id, tenant_id, name, project_code, budget_amount, created_at)
values
  ('00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000001', 'Uganda Project Site', 'UGA-001', 500000000.00, '2026-07-30 11:30:48.602762+00')
on conflict (id) do nothing;

alter table cost_centers enable trigger trg_set_cost_center_defaults;

alter table requests disable trigger trg_set_request_defaults;

insert into requests (id, tenant_id, requester_id, department_id, cost_center_id, current_stage_id, item_description, quantity, status, created_at, updated_at, mr_number)
values
  ('4b1562e3-c2f3-4a75-ad6a-11c4efb40c4e', '00000000-0000-0000-0000-000000000001', 'b93bd287-c359-44cc-a7a6-2dd1578b06ee', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000034', 'A4 Photocopy Paper', 1, 'open', '2026-07-30 12:00:06.313841+00', '2026-07-31 10:33:37.128+00', 'MR-00001'),
  ('d69f1e5f-0996-42d8-87e6-9427ad2d2d2f', '00000000-0000-0000-0000-000000000001', 'b93bd287-c359-44cc-a7a6-2dd1578b06ee', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000034', 'A3 Photocopy Paper', 1, 'open', '2026-07-30 14:31:22.482370+00', '2026-07-31 10:33:40.565+00', 'MR-00002'),
  ('a2f5cbe8-3c80-453a-8aaf-65640d8af8fe', '00000000-0000-0000-0000-000000000001', '833c98a7-31fc-4636-8f47-ed9b7cfbd52b', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000030', 'Diesel Generator', 1, 'rejected', '2026-07-30 15:03:58.024033+00', '2026-07-30 15:04:38.768+00', 'MR-00003'),
  ('197f9963-9892-48d7-8d95-5d0d78f44edf', '00000000-0000-0000-0000-000000000001', '691b759e-6355-4736-b5da-525836ab2bd8', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000034', 'E2E TEST: procurement of 50 safety helmets for Uganda site', 50, 'closed', '2026-07-31 08:57:50.383582+00', '2026-07-31 08:58:43.730213+00', 'MR-00004'),
  ('b4777ecd-c060-4a26-aa63-a01a88ea4f0b', '00000000-0000-0000-0000-000000000001', '833c98a7-31fc-4636-8f47-ed9b7cfbd52b', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000034', 'C-EXV 65 Canon Toner', 1, 'open', '2026-07-31 09:31:36.906219+00', '2026-07-31 11:09:11.692+00', 'MR-00005'),
  ('744803cd-4430-4ffe-9d21-4cdc0866dc28', '00000000-0000-0000-0000-000000000001', '833c98a7-31fc-4636-8f47-ed9b7cfbd52b', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000020', null, 'Generator Diesel', 1, 'closed', '2026-07-31 14:03:13.626226+00', '2026-08-01 08:54:28.502757+00', 'MR-00006'),
  ('cbeb7549-9846-4ccf-b980-206eeccf550c', '00000000-0000-0000-0000-000000000001', '833c98a7-31fc-4636-8f47-ed9b7cfbd52b', '00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000020', null, 'A2 Photocopy Paper', 2, 'closed', '2026-08-01 07:40:16.670519+00', '2026-08-01 08:29:56.397035+00', 'MR-00007'),
  ('1cebfa27-e427-48f2-90af-2d1b35a31cb5', '00000000-0000-0000-0000-000000000001', '6cb314bb-c39e-40e2-aca9-446e12a1795f', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000030', 'HP 953 Cartridges', 5, 'open', '2026-08-01 08:34:52.657926+00', '2026-08-01 08:34:52.657926+00', 'MR-00008')
on conflict (id) do nothing;

alter table requests enable trigger trg_set_request_defaults;

insert into request_line_items (request_id, material_service, cost_code, group_code, place_of_use, quantity, unit_price, currency)
values
  ('4b1562e3-c2f3-4a75-ad6a-11c4efb40c4e', 'A4 Photocopy Paper', 'CC-1010-ADMIN', 'STATIONERY', 'Kampala HQ Office', 1, 45000, 'UGX'),
  ('d69f1e5f-0996-42d8-87e6-9427ad2d2d2f', 'A3 Photocopy Paper', 'CC-1010-ADMIN', 'STATIONERY', 'Kampala HQ Office', 1, 65000, 'UGX'),
  ('a2f5cbe8-3c80-453a-8aaf-65640d8af8fe', 'Diesel Generator', 'CC-2050-SITEPWR', 'EQUIPMENT', 'Malaba Site Camp', 1, 8500000, 'UGX'),
  ('197f9963-9892-48d7-8d95-5d0d78f44edf', 'Safety helmets', 'CC-3070-HSE', 'PPE', 'Uganda Site', 50, 42000, 'UGX'),
  ('b4777ecd-c060-4a26-aa63-a01a88ea4f0b', 'C-EXV 65 Canon Toner', 'CC-1010-ADMIN', 'STATIONERY', 'Kampala HQ Office', 1, 350000, 'UGX'),
  ('744803cd-4430-4ffe-9d21-4cdc0866dc28', 'Generator Diesel', 'CC-2050-SITEPWR', 'FUEL', 'Malaba Site Camp', 1, 1200000, 'UGX'),
  ('cbeb7549-9846-4ccf-b980-206eeccf550c', 'A2 Photocopy Paper', 'CC-1010-ADMIN', 'STATIONERY', 'Kampala HQ Office', 2, 55000, 'UGX'),
  ('1cebfa27-e427-48f2-90af-2d1b35a31cb5', 'HP 953 Cartridges', 'CC-1010-ADMIN', 'STATIONERY', 'Kampala HQ Office', 5, 180000, 'UGX')
on conflict do nothing;
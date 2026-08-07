-- Seed a handful of request_line_items so Request Tracking's Cost Code /
-- Place of use filters have something real to match against. Real,
-- permanent rows (not part of a rolled-back test transaction) tied to
-- existing seeded requests (MR-00001 through MR-00008).

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

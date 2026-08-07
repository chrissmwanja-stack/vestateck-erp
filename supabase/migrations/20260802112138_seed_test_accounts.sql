
insert into public.accounts (tenant_id, account_code, name, account_type, category_id, contact_name, contact_phone, contact_email, is_active)
select (select id from public.tenants limit 1), v.account_code, v.name, v.account_type::text,
       (select id from public.account_categories where code = v.category_code),
       v.contact_name, v.contact_phone, v.contact_email, true
from (values
  ('VEN-0001', 'Roofings Ltd',                'vendor', 'FIRMAC',     'Patrick Ssemwogerere', '+256772100001', 'sales@roofings.co.ug'),
  ('VEN-0002', 'Simba Cement Uganda',         'vendor', 'FIRMAC',     'Grace Nabirye',        '+256772100002', 'accounts@simbacement.com'),
  ('VEN-0003', 'Steel and Tube (U) Ltd',      'vendor', 'FIRMAC',     'David Okello',         '+256772100003', 'finance@steeltube.co.ug'),
  ('VEN-0004', 'Total Energies Uganda',       'vendor', 'FIRMAC',     'Sarah Kyomugisha',     '+256772100004', 'fleet@totalenergies.ug'),
  ('VEN-0005', 'Uganda Revenue Authority',    'vendor', 'GOVT',       'URA Domestic Taxes',   '+256417444602', 'services@ura.go.ug'),
  ('VEN-0006', 'Kampala Capital City Authority', 'vendor', 'GOVT',    'Permits Office',       '+256312221000', 'info@kcca.go.ug'),
  ('VEN-0007', 'James Mugabe (Haulage)',      'vendor', 'INDIVIDUAL', 'James Mugabe',         '+256772100007', null),
  ('CLI-0001', 'Bujagali Hydro Power Co.',    'client', 'FIRMAC',     'Moses Tumwesigye',     '+256772200001', 'contracts@bhpc.co.ug'),
  ('CLI-0002', 'Ministry of Works and Transport', 'client', 'GOVT',   'PS Office',            '+256414230075', 'ps@works.go.ug'),
  ('CLI-0003', 'Uganda National Roads Authority', 'client', 'GOVT',   'Contracts Dept',       '+256312236100', 'info@unra.go.ug'),
  ('BOTH-0001','Stanbic Bank Uganda',         'both',  'FIRMAC',      'Corporate Banking',    '+256312224600', 'corporate@stanbic.co.ug')
) as v(account_code, name, account_type, category_code, contact_name, contact_phone, contact_email)
where not exists (select 1 from public.accounts a where a.account_code = v.account_code);


-- NOTE (2026-09-16): the org names, contact names, phone numbers, and
-- email domains below are entirely fictitious. This file previously
-- named real Ugandan companies and government agencies (URA, KCCA,
-- UNRA, a ministry, a major bank, and named private firms) as vendor/
-- client demo records with invented contact individuals attached.
-- That was a real problem in a public repo -- see the neutralisation
-- note in supabase/seed.sql's header for the full rationale. This
-- file is excluded from fresh replay (migrations_archive/), so the
-- edit here does not change any environment's actual data; it only
-- removes the exposure from the tracked source going forward. Older
-- commits in git history still contain the original names -- purging
-- those (git filter-repo / BFG + force-push) is a separate, deliberate
-- operation, not done as part of this edit.
insert into public.accounts (tenant_id, account_code, name, account_type, category_id, contact_name, contact_phone, contact_email, is_active)
select (select id from public.tenants limit 1), v.account_code, v.name, v.account_type::text,
       (select id from public.account_categories where code = v.category_code),
       v.contact_name, v.contact_phone, v.contact_email, true
from (values
  ('VEN-0001', 'Kiboko Roofing Ltd',              'vendor', 'FIRMAC',     'Patrick Ssali',        '+256700100001', 'sales@kiboko-roofing.example'),
  ('VEN-0002', 'Acacia Cement Uganda',            'vendor', 'FIRMAC',     'Grace Namono',         '+256700100002', 'accounts@acaciacement.example'),
  ('VEN-0003', 'Highland Steel & Tube Ltd',       'vendor', 'FIRMAC',     'David Okwir',          '+256700100003', 'finance@highlandsteel.example'),
  ('VEN-0004', 'Equator Fuels Uganda',            'vendor', 'FIRMAC',     'Sarah Kobusingye',     '+256700100004', 'fleet@equatorfuels.example'),
  ('VEN-0005', 'National Revenue Board',          'vendor', 'GOVT',       'Domestic Taxes Desk',  '+256700100005', 'services@revenueboard.example'),
  ('VEN-0006', 'Capital City Permits Authority',  'vendor', 'GOVT',       'Permits Office',       '+256700100006', 'info@citypermits.example'),
  ('VEN-0007', 'Joseph Mukasa (Haulage)',         'vendor', 'INDIVIDUAL', 'Joseph Mukasa',        '+256700100007', null),
  ('CLI-0001', 'Rift Valley Hydro Power Co.',     'client', 'FIRMAC',     'Moses Tumusiime',      '+256700200001', 'contracts@riftvalleyhydro.example'),
  ('CLI-0002', 'Ministry of Infrastructure and Mobility', 'client', 'GOVT', 'PS Office',          '+256700200002', 'ps@infra-mobility.example'),
  ('CLI-0003', 'National Roads Development Authority', 'client', 'GOVT',  'Contracts Dept',       '+256700200003', 'info@nrda.example'),
  ('BOTH-0001','Continental Trust Bank Uganda',   'both',  'FIRMAC',      'Corporate Banking',    '+256700200004', 'corporate@continentaltrust.example')
) as v(account_code, name, account_type, category_code, contact_name, contact_phone, contact_email)
where not exists (select 1 from public.accounts a where a.account_code = v.account_code);

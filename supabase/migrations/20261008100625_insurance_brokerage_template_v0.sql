-- Phase 1, step 6 of the Insurance Brokerage vertical work: Insurance Brokerage
-- template v0.
--
-- Data only: one industry_templates row and its industry_template_items. No
-- schema change, nothing applied to any tenant (tenants get it at creation via
-- seed_tenant_defaults, or on request via apply_template).
--
-- Contents (agreed scope):
--   * modules:      insurance, hr, it, legal  (finance is always on; no
--                   procurement, pmo, machine_operation, sustainability or bd)
--   * departments:  8, listed below
--   * workflow:     none (the editor validator allows this unless the template
--                   enables procurement)
--   * feature flags: none (platform_feature_flags is empty today)
--   * chart:        18 accounts and 18 posting rules. Extends the default chart's
--                   code scheme (1000-5100). Covers all 13 existing posting roles
--                   plus the 5 insurance roles, so the Chart of Accounts screen's
--                   required-role check passes. Client premiums sit in 1020 / 2010,
--                   off the brokerage's own income; only commission reaches 4000.
--                   Account names and the VAT / WHT accounts are to be confirmed
--                   with the company's accountant; the structure holds either way.
--
-- Idempotent: ON CONFLICT DO NOTHING, so re-running never overwrites later
-- edits made through the template editor.

insert into public.industry_templates (key, name, description, is_active, is_default, sort_order)
values (
  'insurance',
  'Insurance Brokerage',
  'Standalone insurance brokerage: clients, policies, renewals and commission, with a client-money chart of accounts. Core finance, HR, IT Support and Law & Compliance; no construction or procurement modules.',
  true, false, 30
)
on conflict (key) do nothing;

insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select 'insurance', v.kind, v.sort_order, v.name, v.payload
from (values
  ('department', 1, 'Sales & Client Acquisition', '{}'::jsonb),
  ('department', 2, 'Client Service & Account Management', '{}'::jsonb),
  ('department', 3, 'Placement & Insurer Relations', '{}'::jsonb),
  ('department', 4, 'Claims', '{}'::jsonb),
  ('department', 5, 'Finance & Financial Reporting', '{}'::jsonb),
  ('department', 6, 'Compliance & Risk', '{}'::jsonb),
  ('department', 7, 'Human Resources', '{}'::jsonb),
  ('department', 8, 'IT Support', '{}'::jsonb),
  ('module', 1, 'insurance', '{}'::jsonb),
  ('module', 2, 'hr', '{}'::jsonb),
  ('module', 3, 'it', '{}'::jsonb),
  ('module', 4, 'legal', '{}'::jsonb),
  ('gl_account', 1, '1000', '{"name": "Operating Bank", "account_type": "asset", "is_control_account": true}'::jsonb),
  ('gl_account', 2, '1010', '{"name": "Cash", "account_type": "asset", "is_control_account": true}'::jsonb),
  ('gl_account', 3, '1020', '{"name": "Client Money Bank (Premium Trust)", "account_type": "asset", "is_control_account": true}'::jsonb),
  ('gl_account', 4, '1100', '{"name": "Accounts Receivable Control", "account_type": "asset", "is_control_account": true}'::jsonb),
  ('gl_account', 5, '1110', '{"name": "Commission Receivable", "account_type": "asset", "is_control_account": true}'::jsonb),
  ('gl_account', 6, '1200', '{"name": "VAT Input", "account_type": "asset", "is_control_account": true}'::jsonb),
  ('gl_account', 7, '1210', '{"name": "WHT Receivable", "account_type": "asset", "is_control_account": true}'::jsonb),
  ('gl_account', 8, '2000', '{"name": "Accounts Payable Control", "account_type": "liability", "is_control_account": true}'::jsonb),
  ('gl_account', 9, '2010', '{"name": "Insurer Payable (Premiums)", "account_type": "liability", "is_control_account": true}'::jsonb),
  ('gl_account', 10, '2100', '{"name": "VAT Output", "account_type": "liability", "is_control_account": true}'::jsonb),
  ('gl_account', 11, '2200', '{"name": "WHT Payable", "account_type": "liability", "is_control_account": true}'::jsonb),
  ('gl_account', 12, '2300', '{"name": "Salaries Payable", "account_type": "liability", "is_control_account": true}'::jsonb),
  ('gl_account', 13, '2310', '{"name": "PAYE Payable", "account_type": "liability", "is_control_account": true}'::jsonb),
  ('gl_account', 14, '2320', '{"name": "NSSF Payable", "account_type": "liability", "is_control_account": true}'::jsonb),
  ('gl_account', 15, '4000', '{"name": "Commission Income", "account_type": "revenue"}'::jsonb),
  ('gl_account', 16, '4100', '{"name": "Brokerage Fees & Other Income", "account_type": "revenue"}'::jsonb),
  ('gl_account', 17, '5000', '{"name": "General Expense", "account_type": "expense"}'::jsonb),
  ('gl_account', 18, '5100', '{"name": "Salaries Expense", "account_type": "expense"}'::jsonb),
  ('posting_rule', 1, 'bank', '{"account_code": "1000"}'::jsonb),
  ('posting_rule', 2, 'cash', '{"account_code": "1010"}'::jsonb),
  ('posting_rule', 3, 'client_money_bank', '{"account_code": "1020"}'::jsonb),
  ('posting_rule', 4, 'ar_control', '{"account_code": "1100"}'::jsonb),
  ('posting_rule', 5, 'commission_receivable', '{"account_code": "1110"}'::jsonb),
  ('posting_rule', 6, 'vat_input', '{"account_code": "1200"}'::jsonb),
  ('posting_rule', 7, 'wht_receivable', '{"account_code": "1210"}'::jsonb),
  ('posting_rule', 8, 'ap_control', '{"account_code": "2000"}'::jsonb),
  ('posting_rule', 9, 'insurer_payable', '{"account_code": "2010"}'::jsonb),
  ('posting_rule', 10, 'vat_output', '{"account_code": "2100"}'::jsonb),
  ('posting_rule', 11, 'wht_payable', '{"account_code": "2200"}'::jsonb),
  ('posting_rule', 12, 'salaries_payable', '{"account_code": "2300"}'::jsonb),
  ('posting_rule', 13, 'paye_payable', '{"account_code": "2310"}'::jsonb),
  ('posting_rule', 14, 'nssf_payable', '{"account_code": "2320"}'::jsonb),
  ('posting_rule', 15, 'commission_income', '{"account_code": "4000"}'::jsonb),
  ('posting_rule', 16, 'default_revenue', '{"account_code": "4100"}'::jsonb),
  ('posting_rule', 17, 'default_expense', '{"account_code": "5000"}'::jsonb),
  ('posting_rule', 18, 'salaries_expense', '{"account_code": "5100"}'::jsonb)
) as v(kind, sort_order, name, payload)
on conflict (template_key, kind, name) do nothing;

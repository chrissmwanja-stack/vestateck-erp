-- Make BD lead, opportunity, proposal and tender numbers unique per tenant.
--
-- Problem
--   generate_bd_lead_no / generate_bd_opportunity_no / generate_bd_proposal_no /
--   generate_bd_tender_no all call next_doc_number(tenant_id, ...), so every
--   tenant's sequence starts at BD-x-<year>-0001. The baseline, however,
--   enforces GLOBAL uniqueness on bd_leads.lead_no, bd_opportunities.opportunity_no,
--   bd_proposals.proposal_no and bd_tenders.tender_no. The second tenant's first
--   lead, opportunity, proposal or tender therefore fails with a unique violation.
--   Found by test_client_master_access.sql, which seeds the same table for two
--   tenants. 20261001160000 fixed the same bug class for assets, problems and MRs
--   but did not cover these four BD tables.
--
-- Fix
--   Replace each global unique constraint with a (tenant_id, <number>) one. This
--   only loosens uniqueness across tenants, so existing data cannot violate it.

begin;

alter table public.bd_leads drop constraint if exists bd_leads_lead_no_key;
alter table public.bd_leads
  add constraint bd_leads_tenant_id_lead_no_key unique (tenant_id, lead_no);

alter table public.bd_opportunities drop constraint if exists bd_opportunities_opportunity_no_key;
alter table public.bd_opportunities
  add constraint bd_opportunities_tenant_id_opportunity_no_key unique (tenant_id, opportunity_no);

alter table public.bd_proposals drop constraint if exists bd_proposals_proposal_no_key;
alter table public.bd_proposals
  add constraint bd_proposals_tenant_id_proposal_no_key unique (tenant_id, proposal_no);

alter table public.bd_tenders drop constraint if exists bd_tenders_tender_no_key;
alter table public.bd_tenders
  add constraint bd_tenders_tenant_id_tender_no_key unique (tenant_id, tender_no);

commit;
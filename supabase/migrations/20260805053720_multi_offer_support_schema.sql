-- Multi-offer support: procurement can log several competing vendor
-- quotes per request; Budget Controller picks the winner at approval
-- time rather than procurement picking implicitly by only entering one.

-- 1. Allow multiple offers per request, but not duplicate vendors on the
--    same request, and only one can ever be marked selected.
alter table public.request_offers
  add column is_selected boolean not null default false;

alter table public.request_offers
  drop constraint request_offers_one_per_request;

alter table public.request_offers
  add constraint request_offers_unique_vendor_per_request unique (request_id, vendor_name);

create unique index request_offers_one_selected_per_request
  on public.request_offers (request_id)
  where is_selected;

-- 2. Mark which stage is the one where a selection decision happens
--    (Budget Controller) -- mirrors the existing requires_offer_entry
--    pattern on workflow_stages.
alter table public.workflow_stages
  add column requires_offer_selection boolean not null default false;

update public.workflow_stages
  set requires_offer_selection = true
  where id = '00000000-0000-0000-0000-000000000033'; -- Budget Controller (requests)

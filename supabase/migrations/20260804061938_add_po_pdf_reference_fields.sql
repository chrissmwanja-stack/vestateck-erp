-- Fields that appear on the reference "Purchase Order and Approval Form"
-- (project SAP no, payment conditions, terms of delivery) but don't exist
-- anywhere in the schema yet. Added nullable so nothing breaks for
-- existing POs -- the PDF just prints "-" until there's somewhere in the
-- UI to capture them (a follow-up, not part of this change).
alter table public.purchase_orders
  add column if not exists project_sap_no text,
  add column if not exists payment_conditions text,
  add column if not exists terms_of_delivery text;

comment on column public.purchase_orders.project_sap_no is 'Reference-form "PROJECT SAP NO" field. Not yet editable anywhere in the UI.';
comment on column public.purchase_orders.payment_conditions is 'Reference-form "Payment Conditions" field (e.g. "C.H.", "10 Gun Vadeli"). Not yet editable anywhere in the UI.';
comment on column public.purchase_orders.terms_of_delivery is 'Reference-form "Terms of Delivery" field. Not yet editable anywhere in the UI.';

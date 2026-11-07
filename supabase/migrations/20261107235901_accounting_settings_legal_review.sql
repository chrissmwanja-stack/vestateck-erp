-- =====================================================================
-- Add-on to 20261107150000_company_accounting_settings:
-- "configurable is not legally unrestricted".
--
-- 1. accounting_setting_definitions gains requires_legal_review: keys whose
--    applicability is a question of law (tax, WHT, remittance basis), not a
--    company preference.
-- 2. A trigger on company_accounting_settings enforces that a
--    requires_legal_review key can never be marked 'reviewed' by its own
--    creator and always carries a review_reference — a company cannot
--    self-certify a legal treatment.
-- =====================================================================

alter table public.accounting_config_definitions
  add column if not exists requires_legal_review boolean not null default false;

-- (the user's merged table is accounting_setting_definitions; flag there too)
alter table public.accounting_setting_definitions
  add column if not exists requires_legal_review boolean not null default false;

comment on column public.accounting_setting_definitions.requires_legal_review is
  'True when the setting''s applicability is a legal/regulatory question. Such keys cannot be marked reviewed by their creator and always need a review_reference.';

-- Flag the known legal-applicability keys (inserted by later migrations too).
update public.accounting_setting_definitions
set requires_legal_review = true
where key in (
  'ins.agent_commission_taxable',
  'ins.agent_commission_wht',
  'ins.insurer_remittance_basis',
  'ins.broker_fee_vat',
  'migration.earned_commission_treatment'
);

create or replace function public.company_accounting_settings_legal_review_guard()
returns trigger language plpgsql as $$
declare
  v_legal boolean;
begin
  select d.requires_legal_review into v_legal
  from public.accounting_setting_definitions d
  where d.key = new.setting_key;

  if coalesce(v_legal, false) and new.review_status = 'reviewed' then
    if new.reviewed_by is distinct from new.created_by then
      -- ok: different person reviewed
    else
      raise exception 'ACCT_LEGAL_SELF_REVIEW: a legal-applicability setting (%) cannot be reviewed by its proposer', new.setting_key;
    end if;
    if coalesce(btrim(new.review_reference), '') = '' then
      raise exception 'ACCT_LEGAL_REFERENCE_REQUIRED: % needs an accountant/compliance reference', new.setting_key;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists company_accounting_settings_legal_review on public.company_accounting_settings;
create trigger company_accounting_settings_legal_review
  before insert or update on public.company_accounting_settings
  for each row execute function public.company_accounting_settings_legal_review_guard();

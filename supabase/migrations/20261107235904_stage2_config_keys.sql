-- =====================================================================
-- Stage 2: catalogue the tax, commission, remittance and cancellation
-- treatment keys in accounting_setting_definitions.
-- Values are company choices ONLY where legitimate alternatives exist;
-- keys whose applicability is a legal question carry requires_legal_review
-- and can never be self-certified (20261107235901 guard).
-- Defaults are placeholders pending accountant/compliance review.
-- =====================================================================

insert into public.accounting_setting_definitions
  (key, label, description, allowed_values, default_value, requires_legal_review)
values
  ('ins.agent_commission_taxable',
   'Agent commission taxation',
   'Whether agent commission is subject to tax. Legal applicability must be confirmed by an accountant/compliance adviser.',
   array['taxable','not_taxable'], 'taxable', true),
  ('ins.agent_commission_wht',
   'Withholding tax on agent commission',
   'WHT applicability; Ugandan treatment differs between broker and agent commission.',
   array['applicable','not_applicable'], 'applicable', true),
  ('ins.agent_commission_basis',
   'Commission tax calculation basis',
   'Gross vs net-of-deductions basis for any commission tax.',
   array['gross_commission','net_commission'], 'gross_commission', false),
  ('ins.insurer_remittance_basis',
   'Insurer remittance basis',
   'Gross premium vs net of commission. Whether an insurer may legally be paid net is not a free company choice.',
   array['gross_premium','net_of_commission'], 'gross_premium', true),
  ('ins.broker_fee_vat',
   'Broker fee VAT',
   'VAT treatment of broker fees.',
   array['vat_applicable','not_applicable'], 'vat_applicable', true),
  ('ins.commission_earning',
   'Commission earning method',
   'Immediate recognition vs deferred over the earning period.',
   array['immediate','deferred_over_time'], 'deferred_over_time', false),
  ('ins.cancellation_treatment',
   'Cancellation refund & commission reversal',
   'Refund and commission-reversal treatment on cancellation. Free-form policy per agreement; overrides must be explicit and auditable.',
   array['pro_rata_refund','short_rate_refund','no_refund'], 'pro_rata_refund', false),
  ('migration.earned_commission_treatment',
   'Cut-over earned commission treatment',
   'Earned commission at cut-over is recognised in opening balances; alternatives need accountant approval.',
   array['opening_balances','other_approved'], 'opening_balances', true),
  ('migration.partially_paid_import',
   'Partially paid policy import',
   'Import full billed amount plus receipts (reconciles to opening ledger), or verified opening balances only.',
   array['full_billed_plus_receipts','verified_opening_balances_only'], 'full_billed_plus_receipts', false)
on conflict (key) do nothing;

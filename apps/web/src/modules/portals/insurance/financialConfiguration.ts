export interface InsurerShare {
  id?: string;
  insurer_id: string;
  insurer_name?: string;
  is_lead: boolean;
  share_pct: number;
  commission_rate_pct: number;
  insurer_policy_no: string | null;
  reviewed: boolean;
  premium_amount?: number | null;
  pass_through_amount?: number | null;
  commission_amount?: number | null;
  payable_amount?: number | null;
}
export type FeeClass = 'insurance_brokerage' | 'other_taxable_service';

export interface PolicyCharge {
  id?: string;
  kind: 'insurer_pass_through' | 'broker_fee';
  description: string;
  amount: number | null;
  recipient_mode: 'all_insurers' | 'one_insurer' | 'broker';
  recipient_insurer_id: string | null;
  vat_mode: 'not_calculated' | 'exclusive';
  vat_rate_pct: number | null;
  vat_amount?: number | null;
  income_gl_account_id: string | null;
  reviewed: boolean;
  /** Broker fees only. Null for insurer pass-through charges. */
  fee_class?: FeeClass | null;
  /** Required (20+ characters) when fee_class is other_taxable_service. */
  fee_class_reason?: string | null;
  /** Set by the database when the approved standard rate was copied. */
  vat_rate_parameter_ref?: string | null;
}
export const FEE_REASON_MIN_LENGTH = 20;
export interface FinancialSnapshot {
  extended: boolean;
  invoice_total: number;
  broker_fee_total: number;
  vat_total: number;
  journal_entry_id: string;
  bound_by: string;
  bound_at: string;
  snapshot: Record<string, unknown>;
}
export interface FinancialDetails {
  policy_id: string;
  policy_no: string;
  status: string;
  currency: string;
  gross_premium: number;
  shares: InsurerShare[];
  charges: PolicyCharge[];
  snapshot: FinancialSnapshot | null;
  can_configure: boolean;
  client_name: string;
}
export function configurationProblems(
  shares: InsurerShare[],
  charges: PolicyCharge[],
): string[] {
  const errors: string[] = [];
  if (charges.length && !shares.length)
    errors.push('Add explicit insurer shares before adding charges.');
  if (shares.length) {
    // Integer units avoid floating-point summation rejecting e.g. 33.3333%.
    const units = shares.reduce(
      (sum, s) => sum + Math.round(s.share_pct * 10000),
      0,
    );
    if (units !== 1000000)
      errors.push('Insurer shares must total exactly 100%.');
    if (shares.filter((s) => s.is_lead).length !== 1)
      errors.push('Choose exactly one lead insurer.');
    if (new Set(shares.map((s) => s.insurer_id)).size !== shares.length)
      errors.push('Each insurer may appear only once.');
    if (
      shares.some(
        (s) =>
          !s.insurer_id ||
          !Number.isFinite(s.share_pct) ||
          s.share_pct <= 0 ||
          s.share_pct > 100 ||
          !Number.isFinite(s.commission_rate_pct) ||
          s.commission_rate_pct < 0 ||
          s.commission_rate_pct >= 100,
      )
    )
      errors.push('Choose insurers and valid shares/commission rates.');
  }
  for (const c of charges) {
    if (
      !c.description.trim() ||
      (c.amount !== null && (!Number.isFinite(c.amount) || c.amount < 0))
    )
      errors.push('Each charge needs a description and a non-negative amount.');
    if (
      c.recipient_mode === 'one_insurer' &&
      !shares.some((s) => s.insurer_id === c.recipient_insurer_id)
    )
      errors.push(
        'Choose a participating insurer for each insurer-specific charge.',
      );
    if (c.kind === 'broker_fee') {
      if (!c.fee_class)
        errors.push(
          'Choose what kind of supply each broker fee is (insurance brokerage or other taxable service).',
        );
      else if (c.fee_class === 'insurance_brokerage') {
        if (c.vat_mode === 'exclusive' || c.vat_rate_pct !== null)
          errors.push(
            'An insurance brokerage fee is VAT-exempt and cannot carry VAT. If it is a separate taxable service, classify it as one.',
          );
      } else if (
        (c.fee_class_reason ?? '').trim().length < FEE_REASON_MIN_LENGTH
      )
        errors.push(
          `Give a reason of at least ${FEE_REASON_MIN_LENGTH} characters for treating a fee as a taxable service.`,
        );
    }
    // A taxable fee may leave the rate blank: the database then uses the
    // approved standard rate. A rate that is typed must still be sensible.
    // Pass-through charges have no approved default, so their rate is required.
    if (
      c.vat_mode === 'exclusive' &&
      (c.vat_rate_pct === null
        ? !(c.kind === 'broker_fee' && c.fee_class === 'other_taxable_service')
        : c.vat_rate_pct <= 0 || c.vat_rate_pct > 100)
    )
      errors.push(
        'Enter the applicable VAT rate; no statutory rate is assumed.',
      );
    if (
      c.kind === 'broker_fee' &&
      c.amount !== null &&
      c.amount > 0 &&
      !c.income_gl_account_id
    )
      errors.push('Choose an income GL account for each broker fee.');
  }
  return [...new Set(errors)];
}

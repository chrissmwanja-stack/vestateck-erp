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
/** The catalogue columns a charge carries when it was priced from it. */
export interface StatutoryChargeFields {
  catalogue_id?: string | null;
  charge_class?: string | null;
  catalogue_version?: number | null;
  collector?: string | null;
  recipient_name?: string | null;
  payable_role?: string | null;
  catalogue_snapshot?: Record<string, unknown> | null;
}


export type FeeClass = 'insurance_brokerage' | 'other_taxable_service';

export interface PolicyCharge extends StatutoryChargeFields {
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

export type ChargeEnforcement = 'advisory' | 'required';

/** What the policy screen needs to decide whether to show the pricing controls. */
export interface StatutoryState {
  /** The acknowledged figures, or null when nothing has been acknowledged. */
  ack: {
    acknowledged_at?: string;
    total?: number;
    lines?: { code?: string; amount?: number; catalogue_version?: number }[];
  } | null;
  acknowledged: boolean;
  acknowledged_total: number | null;
  /** Total of the lines this mechanism wrote -- manual fees are excluded. */
  priced_total: number;
  priced_count: number;
  enforcement: ChargeEnforcement;
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
  /** Absent on a response from before 20261120010000; treated as advisory. */
  statutory?: StatutoryState | null;
  enforcement?: ChargeEnforcement | null;
}

/**
 * Whether a bind of this policy will be refused for want of acknowledged statutory
 * charges, and why. Pure so the panel stays thin and the rule is testable without a
 * DOM -- the same reason configurationProblems lives here.
 */
export function statutoryProblems(
  details: Pick<FinancialDetails, 'status' | 'statutory' | 'enforcement'>,
): string[] {
  const problems: string[] = [];
  const state = details.statutory ?? null;
  const enforcement: ChargeEnforcement =
    state?.enforcement ?? details.enforcement ?? 'advisory';

  if (enforcement !== 'required') return problems;
  if (details.status !== 'draft' && details.status !== 'approved') return problems;

  // Nothing priced.
  //
  // Whether that BLOCKS the bind depends on whether the catalogue prices anything
  // for this company, and only the database knows that: a company with no verified
  // statutory charge has nothing to price, and the bind allows it. Saying "not
  // priced, fix it" here would put a warning on every policy of every such company
  // -- and a warning that is usually wrong is worse than none, because it teaches
  // people to ignore it.
  //
  // So the screen stays silent and the bind, which can check properly, refuses with
  // INS_CHARGE_NOT_ACKNOWLEDGED and the exact amount owed. What the screen CAN say
  // for certain is the human sequence, which `priced_count === 0` gives in required
  // mode as a hint rather than a problem.
  if (!state || state.priced_count === 0) return problems;
  if (!state.acknowledged) {
    problems.push(
      'Statutory charges are priced but not acknowledged. Acknowledge them before binding.',
    );
    return problems;
  }
  // Acknowledged, but the prices have moved since (someone re-priced).
  if (state.acknowledged_total !== null && state.priced_total !== state.acknowledged_total) {
    problems.push(
      'The statutory charges changed after they were acknowledged. Acknowledge them again before binding.',
    );
  }
  return problems;
}

/** The catalogue-sourced lines only, in the order they were priced. */
export function statutoryLines(
  charges: (PolicyCharge & StatutoryChargeFields)[],
): (PolicyCharge & StatutoryChargeFields)[] {
  return charges.filter((c) => Boolean(c.catalogue_id));
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

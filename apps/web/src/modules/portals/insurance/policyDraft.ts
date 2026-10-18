export interface PolicyDraftForm {
  clientId: string;
  insurerId: string;
  productLineId: string;
  inception: string;
  expiry: string;
  sumInsured: string;
  currency: string;
  grossPremium: string;
  commissionRatePct: string;
  riskDescription: string;
  notes: string;
}

/**
 * The columns written when a draft policy is edited.
 *
 * When the draft already has saved insurer shares, the insurer and the commission rate belong to
 * that configuration: binding requires the policy's insurer to equal the configured lead, and each
 * share carries its own rate. Editing them here would leave the two disagreeing, so they are left
 * out and the Financial configuration panel stays the one place to change them.
 */
export function draftUpdate(form: PolicyDraftForm, hasConfiguration: boolean): Record<string, unknown> {
  const patch: Record<string, unknown> = {
    client_id: form.clientId,
    product_line_id: form.productLineId,
    inception_date: form.inception,
    expiry_date: form.expiry,
    sum_insured: Number(form.sumInsured) || 0,
    currency: form.currency,
    gross_premium: Number(form.grossPremium) || 0,
    risk_description: form.riskDescription.trim() || null,
    notes: form.notes.trim() || null,
  };
  if (!hasConfiguration) {
    patch.insurer_id = form.insurerId;
    patch.commission_rate_pct = Number(form.commissionRatePct) || 0;
  }
  return patch;
}

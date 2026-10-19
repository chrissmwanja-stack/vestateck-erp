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
 *
 * While risks are linked to the draft, its client and product line are locked on the server
 * (ins_policies_link_lock_trg): a linked risk and its certificate were chosen for that client and
 * line. They are left out here too, so the save does not fail on something the form never changed.
 * Unlinking the risks on the policy page lifts the lock.
 */
export function draftUpdate(form: PolicyDraftForm, hasConfiguration: boolean, risksLinked = false): Record<string, unknown> {
  const patch: Record<string, unknown> = {
    inception_date: form.inception,
    expiry_date: form.expiry,
    sum_insured: Number(form.sumInsured) || 0,
    currency: form.currency,
    gross_premium: Number(form.grossPremium) || 0,
    risk_description: form.riskDescription.trim() || null,
    notes: form.notes.trim() || null,
  };
  if (!risksLinked) {
    patch.client_id = form.clientId;
    patch.product_line_id = form.productLineId;
  }
  if (!hasConfiguration) {
    patch.insurer_id = form.insurerId;
    patch.commission_rate_pct = Number(form.commissionRatePct) || 0;
  }
  return patch;
}

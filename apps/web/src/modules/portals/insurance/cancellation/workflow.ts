import type {
  InsurerCancellationCalculation,
  InsurerCancellationTerms,
  ShortPeriodBand,
} from './calculation';
export interface CancellationQuote {
  stage: 'calculation_only';
  payment_authorized: false;
  invoice_credit: string;
  receivable_credit: string;
  client_refund_due: string;
  insurer_balances?: {
    insurer_id: string;
    insurer_share_id: string | null;
    item_id: string;
    outstanding: string;
  }[];
  cash_position?: {
    collected: string;
    remitted: string;
    commission_transferred: string;
  };
  commission_entries?: { insurer_share_id: string | null; status: string }[];
  requires_finance_exception: boolean;
  insurers: (InsurerCancellationCalculation & {
    pass_through_refund: string;
    total_insurer_credit: string;
  })[];
  charges: {
    charge_id: string;
    kind: string;
    refund_base: string;
    refund_vat: string;
    basis: string;
  }[];
}
export interface CancellationCase {
  id: string;
  status: 'proposed' | 'prepared' | 'posted' | 'rejected' | 'withdrawn';
  proposed_by: string;
  proposed_at: string;
  prepared_by: string | null;
  checked_by: string | null;
  cancellation_no: string | null;
  effective_date: string;
  posting_date: string | null;
  insurer_terms: { insurer_id: string; terms: InsurerCancellationTerms }[];
  charge_refunds: {
    charge_id: string;
    refund_amount: string;
    basis: string;
    insurer_refunds?: {
      insurer_id: string;
      refund_amount: string;
      basis: string;
    }[];
  }[];
  accounting_mappings?: { commission_treatment: string };
  reason: string;
  calculation: CancellationQuote;
  clearing_gl_account_id: string | null;
  review_note: string | null;
  refund_item_id: string | null;
  credits: {
    credit_note_id: string;
    credit_note_no: string;
    amount: string | number;
    journal_entry_id: string;
  }[];
  journals: { journal_entry_id: string; purpose: string }[];
  insurer_adjustments: {
    insurer_id: string;
    insurer_name: string;
    payable_credit: string | number;
    recovery_due: string | number;
    retained_commission: string | number;
    transferred_clawback_due: string | number;
  }[];
}
export interface CancellationContext {
  policy_id: string;
  policy_no: string;
  policy_status: string;
  currency: string;
  actor_id: string;
  can_propose: boolean;
  can_finance: boolean;
  has_claims: boolean;
  has_live_case?: boolean;
  inception_date: string;
  expiry_date: string;
  offset: number;
  has_more: boolean;
  insurers: {
    insurer_id: string;
    insurer_name: string;
    premium_amount: string;
    commission_amount: string;
    commission_rate_pct: string;
  }[];
  charges: {
    id: string;
    description: string;
    kind: 'broker_fee' | 'insurer_pass_through';
    amount: string;
    vat_amount: string;
    original_allocations: {
      insurer_id: string;
      insurer_name: string;
      amount: string;
    }[];
  }[];
  cases: CancellationCase[];
  clearing_accounts: { id: string; name: string; account_code: string }[];
}
export interface TermsDraft {
  method: '' | InsurerCancellationTerms['method'];
  reference: string;
  prorataPermitted: boolean;
  minimum: string;
  bands: string;
  manualReturn: string;
}
export interface ChargeDraft {
  refund: string;
  basis: string;
  confirmed: boolean;
  recipients: Record<string, { refund: string; basis: string }>;
}
export const newTermsDraft = (): TermsDraft => ({
  method: '',
  reference: '',
  prorataPermitted: false,
  minimum: '',
  bands: '',
  manualReturn: '',
});
export function parseShortPeriodBands(value: string): ShortPeriodBand[] {
  const lines = value
    .split(/\r?\n/)
    .map((s) => s.trim())
    .filter(Boolean);
  if (!lines.length || lines.length > 100)
    throw new Error('Enter the complete contractual short-period schedule.');
  return lines.map((line) => {
    const match = /^(\d{1,7})\s*:\s*(\d{1,3}(?:\.\d{1,4})?)$/.exec(line);
    if (!match)
      throw new Error(
        'Use one “through day : retained %” band per line, for example 30:20.',
      );
    return { through_day: Number(match[1]), retained_pct: match[2] };
  });
}
export function cancellationPayload(
  context: CancellationContext,
  effective: string,
  reason: string,
  terms: Record<string, TermsDraft>,
  charges: Record<string, ChargeDraft>,
) {
  if (reason.trim().length < 5)
    throw new Error('Enter the cancellation reason.');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(effective))
    throw new Error('Choose an effective cancellation date.');
  const insurerTerms = context.insurers.map((insurer) => {
    const draft = terms[insurer.insurer_id];
    if (!draft?.method || draft.reference.trim().length < 5)
      throw new Error(
        `Record ${insurer.insurer_name}’s cancellation method and contract reference.`,
      );
    if (draft.method === 'pro_rata' && !draft.prorataPermitted)
      throw new Error('Pro-rata requires affirmative contractual permission.');
    const rule: InsurerCancellationTerms = {
      method: draft.method,
      contract_reference: draft.reference.trim(),
      minimum_retained_premium: draft.minimum || '0',
    };
    if (draft.method === 'pro_rata') rule.pro_rata_permitted = true;
    if (draft.method === 'short_period')
      rule.short_period_bands = parseShortPeriodBands(draft.bands);
    if (draft.method === 'manual_review')
      rule.manual_return_premium = draft.manualReturn;
    return { insurer_id: insurer.insurer_id, terms: rule };
  });
  const chargeRefunds = context.charges.map((charge) => {
    const draft = charges[charge.id];
    if (!draft?.confirmed || draft.basis.trim().length < 5)
      throw new Error(
        'Confirm every charge’s legal/contractual refund or retention basis, including zero amounts.',
      );
    if (!/^\d+(\.\d{1,2})?$/.test(draft.refund))
      throw new Error('Enter an explicit refundable amount, including zero.');
    return {
      charge_id: charge.id,
      refund_amount: draft.refund,
      legal_basis_confirmed: true,
      basis: draft.basis.trim(),
      ...(charge.kind === 'insurer_pass_through'
        ? {
            insurer_refunds: charge.original_allocations.map((recipient) => {
              const item = draft.recipients[recipient.insurer_id];
              if (
                !item ||
                !/^\d+(\.\d{1,2})?$/.test(item.refund) ||
                item.basis.trim().length < 5
              )
                throw new Error(
                  'Each original pass-through recipient needs its own refund amount and basis.',
                );
              return {
                insurer_id: recipient.insurer_id,
                refund_amount: item.refund,
                basis: item.basis.trim(),
              };
            }),
          }
        : {}),
    };
  });
  return {
    p_policy_id: context.policy_id,
    p_effective_date: effective,
    p_insurer_terms: insurerTerms,
    p_charge_refunds: chargeRefunds,
    p_reason: reason.trim(),
  };
}
/** Hints only; database checks identity, Finance role, state and current amounts. */
export function cancellationCaseActions(
  context: Pick<CancellationContext, 'actor_id' | 'can_finance'> & {
    can_propose?: boolean;
  },
  row: CancellationCase,
): ('prepare' | 'approve' | 'reject' | 'withdraw')[] {
  const open = row.status === 'proposed' || row.status === 'prepared';
  if (!open) return [];
  const actions: ('prepare' | 'approve' | 'reject' | 'withdraw')[] = [];
  if (
    row.proposed_by === context.actor_id &&
    (context.can_finance || context.can_propose)
  )
    actions.push('withdraw');
  if (context.can_finance) {
    if (row.status === 'proposed' || row.prepared_by === context.actor_id)
      actions.push('prepare');
    if (
      row.proposed_by !== context.actor_id &&
      row.prepared_by !== context.actor_id
    ) {
      actions.push('reject');
      if (row.status === 'prepared') actions.push('approve');
    }
  }
  return actions;
}

/** Fail closed on a missing migration, stale RPC shape, or wrong-policy result.
 * Never turn unavailable cancellation data into "no proposals" or cash authority.
 */
export function parseCancellationContext(
  value: unknown,
  policyId: string,
): CancellationContext {
  const object = (x: unknown): x is Record<string, unknown> =>
    typeof x === 'object' && x !== null && !Array.isArray(x);
  const arrays = (x: Record<string, unknown>, keys: string[]) =>
    keys.every((key) => Array.isArray(x[key]));
  if (
    !object(value) ||
    value.policy_id !== policyId ||
    typeof value.actor_id !== 'string' ||
    typeof value.policy_status !== 'string' ||
    typeof value.can_finance !== 'boolean' ||
    typeof value.can_propose !== 'boolean' ||
    !arrays(value, ['insurers', 'charges', 'cases', 'clearing_accounts'])
  )
    throw new Error(
      'Cancellation details are unavailable or incomplete. Refresh after confirming the cancellation migration is installed.',
    );
  const rows = value.cases as unknown[];
  if (
    !rows.every(
      (row) =>
        object(row) &&
        object(row.calculation) &&
        arrays(row.calculation, ['insurers', 'charges']) &&
        arrays(row, [
          'insurer_terms',
          'charge_refunds',
          'credits',
          'journals',
          'insurer_adjustments',
        ]),
    )
  )
    throw new Error(
      'Cancellation audit details are incomplete. Refresh before taking any action.',
    );
  if (
    !(value.charges as unknown[]).every(
      (charge) => object(charge) && Array.isArray(charge.original_allocations),
    )
  )
    throw new Error(
      'Original charge recipients are unavailable. Cancellation must be reviewed before proceeding.',
    );
  return value as unknown as CancellationContext;
}

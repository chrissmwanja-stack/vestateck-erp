/** Cancellation calculation primitives, not a posting or payment authority.
 * All money is decimal text. BigInt arithmetic keeps cents exact even above
 * JavaScript's safe-number range. Server-side validation is still mandatory.
 */
export type Money = string;
export type CancellationMethod =
  'pro_rata' | 'short_period' | 'non_refundable' | 'manual_review';
export interface ShortPeriodBand {
  through_day: number;
  retained_pct: string;
}
export interface InsurerCancellationTerms {
  method: CancellationMethod;
  contract_reference: string;
  pro_rata_permitted?: boolean;
  minimum_retained_premium?: Money;
  short_period_bands?: ShortPeriodBand[];
  /** An unresolved calculation is never converted into an automatic refund. */
  manual_return_premium?: Money;
  finance_exception_approved?: boolean;
}
export interface BoundInsurerAllocation {
  insurer_id: string;
  premium_amount: Money;
  commission_amount: Money;
  commission_rate_pct: string;
}
export interface InsurerCancellationCalculation {
  insurer_id: string;
  method: CancellationMethod;
  contract_reference: string;
  original_premium: Money;
  retained_premium: Money;
  return_premium: Money;
  original_commission: Money;
  commission_clawback: Money;
  net_insurer_credit: Money;
  requires_finance_exception: boolean;
}
export class CancellationReviewRequired extends Error {
  readonly code = 'INS_CANCELLATION_REVIEW_REQUIRED';
}
function fail(message: string): never {
  throw new Error(`INS_CANCELLATION_INPUT: ${message}`);
}
export function cents(value: Money): bigint {
  if (typeof value !== 'string' || !/^\d{1,16}(\.\d{1,2})?$/.test(value))
    fail(
      'Money must be non-negative decimal text with at most two decimal places.',
    );
  const [whole, fraction = ''] = value.split('.');
  return BigInt(whole) * 100n + BigInt(fraction.padEnd(2, '0'));
}
export function money(value: bigint): Money {
  if (value < 0n) fail('Negative money is not allowed.');
  return `${value / 100n}.${String(value % 100n).padStart(2, '0')}`;
}
function percentage(value: string, allow100 = true): bigint {
  if (typeof value !== 'string' || !/^\d{1,3}(\.\d{1,4})?$/.test(value))
    fail('Percentage must have at most four decimals.');
  const [whole, fraction = ''] = value.split('.');
  const n = BigInt(whole) * 10000n + BigInt(fraction.padEnd(4, '0'));
  if (n > 1000000n || (!allow100 && n === 1000000n))
    fail('Percentage is outside its permitted range.');
  return n;
}
function roundRatio(numerator: bigint, denominator: bigint): bigint {
  if (denominator <= 0n || numerator < 0n) fail('Invalid non-negative ratio.');
  return (numerator * 2n + denominator) / (denominator * 2n);
}
function day(value: string): number {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || value.startsWith('0000-'))
    fail('Use an ISO calendar date.');
  const n = Date.parse(`${value}T00:00:00Z`);
  if (!Number.isFinite(n) || new Date(n).toISOString().slice(0, 10) !== value)
    fail('Invalid calendar date.');
  return Math.floor(n / 86400000);
}
/** Cover dates are inclusive. Cancellation takes effect at the start of its
 * effective day, which is not earned cover. The day after expiry returns zero.
 * Accounting must be posted separately on the current open accounting date.
 */
export function coverageDays(
  inception: string,
  expiry: string,
  effective: string,
): { total: number; used: number; unused: number } {
  const start = day(inception),
    end = day(expiry),
    cancel = day(effective);
  if (end < start || cancel < start || cancel > end + 1)
    fail('Cancellation date is outside the policy cover period.');
  const total = end - start + 1,
    used = cancel - start;
  return { total, used, unused: total - used };
}
export function calculateInsurerCancellation(
  allocation: BoundInsurerAllocation,
  terms: InsurerCancellationTerms,
  dates: { inception: string; expiry: string; effective: string },
): InsurerCancellationCalculation {
  const premium = cents(allocation.premium_amount),
    originalCommission = cents(allocation.commission_amount);
  const rate = percentage(allocation.commission_rate_pct, false);
  if (
    !allocation.insurer_id ||
    premium <= 0n ||
    originalCommission !== roundRatio(premium * rate, 1000000n)
  )
    fail('Bound allocation and original commission terms do not reconcile.');
  if (!terms.contract_reference || terms.contract_reference.trim().length < 5)
    throw new CancellationReviewRequired(
      'Insurer-specific contractual terms or evidence must be recorded.',
    );
  const period = coverageDays(dates.inception, dates.expiry, dates.effective);
  const minimum = cents(terms.minimum_retained_premium ?? '0');
  if (minimum > premium)
    fail('Minimum retained premium exceeds the original insurer premium.');
  let retained: bigint;
  switch (terms.method) {
    case 'pro_rata':
      if (terms.short_period_bands?.length)
        throw new CancellationReviewRequired(
          'Specific short-period terms take priority over fallback pro-rata.',
        );
      if (terms.pro_rata_permitted !== true)
        throw new CancellationReviewRequired(
          'Confirm that this insurer’s contract permits pro-rata cancellation.',
        );
      // Round the return (not the earned amount), then derive the complement.
      retained =
        premium -
        roundRatio(premium * BigInt(period.unused), BigInt(period.total));
      break;
    case 'short_period': {
      const bands = terms.short_period_bands;
      if (!bands || !bands.length || bands.length > 100)
        throw new CancellationReviewRequired(
          'A complete insurer-specific short-period schedule is required.',
        );
      let previousDay = -1,
        previousRate = -1n;
      for (const band of bands) {
        const bandRate = percentage(band.retained_pct);
        if (
          !Number.isSafeInteger(band.through_day) ||
          band.through_day <= previousDay ||
          bandRate < previousRate
        )
          fail(
            'Short-period bands must have unique increasing days and non-decreasing retained rates.',
          );
        previousDay = band.through_day;
        previousRate = bandRate;
      }
      if (previousDay < period.total || previousRate !== 1000000n)
        throw new CancellationReviewRequired(
          'The final short-period band must cover the full term and retain 100%.',
        );
      const band = bands.find((b) => period.used <= b.through_day)!;
      retained = roundRatio(premium * percentage(band.retained_pct), 1000000n);
      break;
    }
    case 'non_refundable':
      retained = premium;
      break;
    case 'manual_review':
      if (terms.manual_return_premium === undefined)
        throw new CancellationReviewRequired(
          'Finance must determine the return premium; no rate is invented.',
        );
      if (cents(terms.manual_return_premium) > premium)
        fail('Manual return exceeds the original insurer premium.');
      retained = premium - cents(terms.manual_return_premium);
      break;
    default:
      return fail('Unknown cancellation method.');
  }
  // Minimum-retained and expiry rules apply to every calculation method.
  if (retained < minimum) retained = minimum;
  if (period.unused === 0) retained = premium;
  const returned = premium - retained;
  const clawback =
    returned === premium
      ? originalCommission
      : roundRatio(returned * rate, 1000000n);
  if (clawback > originalCommission || clawback > returned)
    fail(
      'Calculated commission clawback exceeds its original amount or return premium.',
    );
  return {
    insurer_id: allocation.insurer_id,
    method: terms.method,
    contract_reference: terms.contract_reference.trim(),
    original_premium: money(premium),
    retained_premium: money(retained),
    return_premium: money(returned),
    original_commission: money(originalCommission),
    commission_clawback: money(clawback),
    net_insurer_credit: money(returned - clawback),
    // Input flags cannot approve an exception. Approval must be a separate,
    // server-authorized operation by a different Finance actor.
    requires_finance_exception: terms.method === 'manual_review',
  };
}
export interface BoundChargeAllocation {
  insurer_id: string;
  amount: Money;
}
/** Proportional estimate only; recipient-specific contractual decisions must
 * be validated separately before approval. Allocate a refund against the actual original per-charge allocations, not
 * equally and not by today's shares. Largest remainder, UUID/string tie-break.
 */
export function allocatePassThroughRefund(
  original: BoundChargeAllocation[],
  refund: Money,
): BoundChargeAllocation[] {
  const amount = cents(refund);
  if (
    !original.length ||
    new Set(original.map((x) => x.insurer_id)).size !== original.length ||
    original.some((x) => !x.insurer_id)
  )
    fail('Unique original charge recipients are required.');
  const total = original.reduce((sum, x) => sum + cents(x.amount), 0n);
  if (amount > total) fail('Charge refund exceeds the original charge.');
  if (total === 0n)
    return original.map((x) => ({ insurer_id: x.insurer_id, amount: '0.00' }));
  const shares = original.map((x) => ({
    insurer_id: x.insurer_id,
    base: (amount * cents(x.amount)) / total,
    remainder: (amount * cents(x.amount)) % total,
  }));
  let extra = amount - shares.reduce((sum, x) => sum + x.base, 0n);
  const ranked = [...shares].sort((a, b) =>
    a.remainder === b.remainder
      ? a.insurer_id < b.insurer_id
        ? -1
        : 1
      : a.remainder > b.remainder
        ? -1
        : 1,
  );
  for (const x of ranked) {
    if (extra === 0n) break;
    x.base += 1n;
    extra -= 1n;
  }
  return shares.map((x) => ({
    insurer_id: x.insurer_id,
    amount: money(x.base),
  }));
}
export interface ChargeRefundCalculation {
  refund_base: Money;
  refund_vat: Money;
  refund_total: Money;
  retained_base: Money;
  retained_vat: Money;
}
/** Tax credits follow the original charged VAT, never today's rate. This is a
 * calculation only: legal entitlement and the tax document still need review.
 */
export function calculateBrokerFeeRefund(
  originalBase: Money,
  originalVat: Money,
  refundBase: Money,
): ChargeRefundCalculation {
  const base = cents(originalBase),
    vat = cents(originalVat),
    refund = cents(refundBase);
  if (refund > base || (base === 0n && vat !== 0n))
    fail('Broker-fee refund or original VAT is inconsistent.');
  const vatRefund =
    base === 0n ? 0n : refund === base ? vat : roundRatio(vat * refund, base);
  return {
    refund_base: money(refund),
    refund_vat: money(vatRefund),
    refund_total: money(refund + vatRefund),
    retained_base: money(base - refund),
    retained_vat: money(vat - vatRefund),
  };
}
/** A cancellation credit first reduces unpaid receivables. It is not all cash
 * owed back, and even the cash refund due is not a payment authorization.
 */
export function splitClientCancellationCredit(
  totalCredit: Money,
  unpaidReceivable: Money,
): { receivable_credit: Money; refund_due: Money } {
  const total = cents(totalCredit),
    unpaid = cents(unpaidReceivable);
  const againstReceivable = total < unpaid ? total : unpaid;
  return {
    receivable_credit: money(againstReceivable),
    refund_due: money(total - againstReceivable),
  };
}

export interface PassThroughRefundDecision {
  insurer_id: string;
  refund_amount: Money;
  basis: string;
}
/** Each insurer may have different refundable/retained charge terms. Never
 * force a contractual refund through a pooled/equal/proportional allocation.
 */
export function calculatePassThroughRefund(
  original: BoundChargeAllocation[],
  decisions: PassThroughRefundDecision[],
): {
  refund_total: Money;
  recipients: {
    insurer_id: string;
    original_amount: Money;
    refund_amount: Money;
    retained_amount: Money;
    basis: string;
  }[];
} {
  if (
    !original.length ||
    new Set(original.map((x) => x.insurer_id)).size !== original.length ||
    original.some((x) => !x.insurer_id) ||
    decisions.length !== original.length ||
    new Set(decisions.map((x) => x.insurer_id)).size !== decisions.length
  )
    fail(
      'One explicit charge decision per original insurer recipient is required.',
    );
  const recipients = original.map((x) => {
    const decision = decisions.find((d) => d.insurer_id === x.insurer_id);
    if (!decision || decision.basis.trim().length < 5)
      throw new CancellationReviewRequired(
        'Record each recipient’s refundable/retained charge basis.',
      );
    const amount = cents(x.amount),
      refund = cents(decision.refund_amount);
    if (refund > amount)
      fail('Recipient charge refund exceeds its original allocation.');
    return {
      insurer_id: x.insurer_id,
      original_amount: money(amount),
      refund_amount: money(refund),
      retained_amount: money(amount - refund),
      basis: decision.basis.trim(),
    };
  });
  return {
    recipients,
    refund_total: money(
      recipients.reduce((sum, x) => sum + cents(x.refund_amount), 0n),
    ),
  };
}

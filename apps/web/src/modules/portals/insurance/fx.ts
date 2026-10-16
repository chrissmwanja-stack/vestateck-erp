// Exchange-rate rules for the insurance UI. The server (fx_rates_guard, fx_rate_approve,
// fx_rate_withdraw, fx_get_rate) is the enforcement point. These helpers only mirror
// its rules so the user sees the problem before submitting, and decide which buttons
// to show. A rate is stated as functional-currency units per 1 unit of the foreign
// currency. Approved and withdrawn rates are never edited; a wrong rate is corrected
// by entering a new one.

export const FX_CURRENCY_PATTERN = /^[A-Z]{3}$/;
export const FX_MAX_DECIMALS = 10; // fx_rates.rate is numeric(24,10)
export const FX_MIN_REASON_LENGTH = 5;

export type FxRateStatus = 'draft' | 'approved' | 'withdrawn';

export interface FxRate {
  id: string;
  tenant_id: string;
  currency: string;
  rate_date: string;
  rate: number;
  source: string;
  status: FxRateStatus;
  entered_by: string | null;
  approved_by: string | null;
  approved_at: string | null;
  withdrawn_reason: string | null;
  created_at: string;
}

export const FX_STATUS_LABEL: Record<FxRateStatus, string> = {
  draft: 'Draft, awaiting approval',
  approved: 'Approved',
  withdrawn: 'Withdrawn',
};

export interface FxRateInput {
  currency: string;
  rateDate: string; // yyyy-mm-dd
  rate: string; // as typed
  source: string;
}

export type FxRateEntryResult =
  | { ok: true; value: { currency: string; rate_date: string; rate: number; source: string } }
  | { ok: false; errors: Partial<Record<keyof FxRateInput, string>> };

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** Validates a draft rate the way fx_rates_guard does, plus the input format. */
export function validateFxRateEntry(input: FxRateInput, functionalCurrency: string, today: string): FxRateEntryResult {
  const errors: Partial<Record<keyof FxRateInput, string>> = {};
  const currency = input.currency.trim().toUpperCase();

  if (!FX_CURRENCY_PATTERN.test(currency)) {
    errors.currency = 'Use the three-letter ISO code, for example USD.';
  } else if (currency === functionalCurrency.toUpperCase()) {
    errors.currency = `${currency} is the company's own currency. Its rate is always 1, so there is nothing to enter.`;
  }

  if (!ISO_DATE.test(input.rateDate)) {
    errors.rateDate = 'Enter the date the rate applies to.';
  } else if (input.rateDate > today) {
    errors.rateDate = 'A rate cannot be dated in the future.';
  }

  const text = input.rate.trim();
  const rate = Number(text);
  const decimals = text.includes('.') ? text.split('.')[1].length : 0;
  if (text === '' || !Number.isFinite(rate) || rate <= 0) {
    errors.rate = 'Enter a rate greater than zero.';
  } else if (decimals > FX_MAX_DECIMALS) {
    errors.rate = `Use at most ${FX_MAX_DECIMALS} decimal places.`;
  }

  if (input.source.trim() === '') {
    errors.source = 'Give the source, for example the central bank bulletin or the date it was taken from.';
  }

  if (Object.keys(errors).length > 0) return { ok: false, errors };
  return { ok: true, value: { currency, rate_date: input.rateDate, rate, source: input.source.trim() } };
}

/** A draft can be approved by someone other than the person who entered it. */
export function canApproveFxRate(rate: Pick<FxRate, 'status' | 'entered_by'>, userId: string | null, canApproveRole: boolean): boolean {
  return canApproveRole && rate.status === 'draft' && userId !== null && rate.entered_by !== userId;
}

/** A draft can be withdrawn by the person who entered it, or by a company admin. */
export function canWithdrawFxRate(rate: Pick<FxRate, 'status' | 'entered_by'>, userId: string | null, isCompanyAdmin: boolean): boolean {
  return rate.status === 'draft' && (isCompanyAdmin || (userId !== null && rate.entered_by === userId));
}

export function isValidFxWithdrawReason(reason: string): boolean {
  return reason.trim().length >= FX_MIN_REASON_LENGTH;
}

/** Shows a rate with no trailing zeros, for example 3700.5 rather than 3700.5000000000. */
export function formatFxRate(rate: number): string {
  return rate.toLocaleString('en-UG', { maximumFractionDigits: FX_MAX_DECIMALS, useGrouping: false });
}

/** Today's date in the user's local timezone, as yyyy-mm-dd. */
export function localIsoDate(now: Date = new Date()): string {
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, '0');
  const d = String(now.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

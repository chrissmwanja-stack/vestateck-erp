// The business day.
//
// The platform's business day is Africa/Kampala (UTC+3, no daylight saving). The
// database already follows it for insurance (ins_local_today(), ins_local_date();
// DR-46 in docs/insurance-brokerage/INSURANCE_DECISIONS_REGISTER.md). The browser
// must use the same day, or a screen opened between 00:00 and 03:00 in Kampala
// fills a date field with yesterday's date while the server validates against
// today's.
//
// Never build "today" from `new Date().toISOString().slice(0, 10)` (that is the
// UTC date) or from `new Date().getFullYear()` and friends (that is the browser's
// own time zone, wrong for anyone outside Uganda). A test in this folder fails the
// build if either pattern comes back in the insurance or finance code.
//
// This file is copied byte for byte to supabase/functions/_shared/businessDate.ts
// for the edge functions, and a test fails if the two differ. Edit both together.
// To move to a per-company time zone later, change BUSINESS_TIME_ZONE (or read it
// from a tenant setting) here and in ins_local_date()/ins_local_today().

export const BUSINESS_TIME_ZONE = 'Africa/Kampala';

const formatter = new Intl.DateTimeFormat('en-US', {
  timeZone: BUSINESS_TIME_ZONE,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
});

const timeFormatter = new Intl.DateTimeFormat('en-US', {
  timeZone: BUSINESS_TIME_ZONE,
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
});

const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

/** The business-day calendar date (yyyy-mm-dd) of an instant. */
export function businessDateOf(instant: Date | string | number): string {
  const d = instant instanceof Date ? instant : new Date(instant);
  if (Number.isNaN(d.getTime())) throw new RangeError(`Not a valid date: ${String(instant)}`);
  const p: Record<string, string> = {};
  for (const part of formatter.formatToParts(d)) p[part.type] = part.value;
  return `${p.year}-${p.month}-${p.day}`;
}

/** Today's business-day date, yyyy-mm-dd. Pass `now` only in tests. */
export const businessToday = (now: Date = new Date()): string => businessDateOf(now);

/** Now on the business-day clock as yyyy-mm-ddThh:mm, the value an <input type="datetime-local"> takes. */
export function businessNowLocalInput(now: Date = new Date()): string {
  const p: Record<string, string> = {};
  for (const part of timeFormatter.formatToParts(now)) p[part.type] = part.value;
  return `${businessToday(now)}T${p.hour}:${p.minute}`;
}

/** Any instant as business-day wall clock, yyyy-mm-ddThh:mm, for filling an <input type="datetime-local">. */
export const businessLocalInputOf = (instant: Date | string | number): string =>
  businessNowLocalInput(new Date(instant));

/**
 * The fixed UTC offset of BUSINESS_TIME_ZONE. Africa/Kampala has no daylight saving, so
 * one offset is exact for every date; a test checks it against Intl. If the zone ever
 * gains daylight saving, or becomes a per-company setting, replace this with a lookup
 * per instant.
 */
export const BUSINESS_UTC_OFFSET = '+03:00';

/**
 * An <input type="datetime-local"> value, read as business-day wall clock, as the instant
 * it means (ISO string, UTC). The inverse of businessLocalInputOf(). Never use
 * `new Date(value)` for this: that reads the value in the browser's own zone, which is
 * wrong for anyone outside Uganda.
 */
export function businessLocalInputToIso(value: string): string {
  const m = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(?::(\d{2}))?$/.exec(value);
  const d = m ? new Date(`${m[1]}T${m[2]}:${m[3] ?? '00'}${BUSINESS_UTC_OFFSET}`) : null;
  if (!d || Number.isNaN(d.getTime())) throw new RangeError(`Not a datetime-local value: ${value}`);
  return d.toISOString();
}

/** The business-day month, yyyy-mm. */
export const businessMonth = (now: Date = new Date()): string => businessToday(now).slice(0, 7);

/** First day of the business-day month, yyyy-mm-dd. */
export const businessMonthStart = (now: Date = new Date()): string => `${businessToday(now).slice(0, 8)}01`;

/** First day of the business-day year, yyyy-mm-dd. */
export const businessYearStart = (now: Date = new Date()): string => `${businessToday(now).slice(0, 4)}-01-01`;

function parseIso(iso: string): { y: number; m: number; d: number } {
  const match = ISO_DATE.exec(iso);
  if (!match) throw new RangeError(`Not a yyyy-mm-dd date: ${iso}`);
  return { y: Number(match[1]), m: Number(match[2]), d: Number(match[3]) };
}

const toIso = (y: number, m: number, d: number): string =>
  `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;

/** Calendar arithmetic on a yyyy-mm-dd date. No time zone is involved. */
export function addDaysIso(iso: string, days: number): string {
  const { y, m, d } = parseIso(iso);
  const t = new Date(Date.UTC(y, m - 1, d + days));
  return toIso(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
}

/** Adds calendar months; a day past the end of the target month falls back to its last day. */
export function addMonthsIso(iso: string, months: number): string {
  const { y, m, d } = parseIso(iso);
  const total = y * 12 + (m - 1) + months;
  const ty = Math.floor(total / 12);
  const tm = (total % 12 + 12) % 12;
  const last = new Date(Date.UTC(ty, tm + 1, 0)).getUTCDate();
  return toIso(ty, tm + 1, Math.min(d, last));
}

export const addYearsIso = (iso: string, years: number): string => addMonthsIso(iso, years * 12);

/**
 * A Date at local noon on the business-day calendar date, for older pure helpers
 * that read getFullYear()/getMonth()/getDate() from a Date they are given. Noon
 * keeps the date stable across daylight-saving changes in the browser's own zone.
 * New code should use businessToday() and the *Iso helpers instead.
 */
export function businessTodayDate(now: Date = new Date()): Date {
  const { y, m, d } = parseIso(businessToday(now));
  return new Date(y, m - 1, d, 12, 0, 0, 0);
}

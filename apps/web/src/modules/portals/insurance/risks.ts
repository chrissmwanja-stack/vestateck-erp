// Insured-risk register and certificate stock: pure rules shared by the screens.
// The server (ins_register_risk, ins_load_certificate_range, ...) enforces the
// same rules; these checks give the user an answer before a round trip.

export const RISK_TYPES = [
  { value: 'vehicle', label: 'Vehicle' },
  { value: 'property', label: 'Property' },
  { value: 'other', label: 'Other' },
] as const;

export type RiskType = (typeof RISK_TYPES)[number]['value'];

export const MOTOR_LINE_CODE = 'MOTOR';

export interface CertificateLine {
  code: string;
  requires_certificate?: boolean | null;
}

/**
 * Whether policies on a product line need an issued certificate before binding, and their risks
 * must be vehicles with a chassis number. Mirrors platform_ins_line_needs_certificate on the
 * server: the flag on the line, or the code MOTOR, which always needs one.
 */
export function lineNeedsCertificate(line: CertificateLine | null | undefined): boolean {
  return !!line && (line.requires_certificate === true || line.code === MOTOR_LINE_CODE);
}

/** A line that looks like motor business by its code or name, to prompt the admin to check the flag. */
export function looksLikeMotorLine(code: string, name: string): boolean {
  return /^MOT/i.test(code.trim()) || /motor|vehicle|automobile/i.test(name);
}

export const CERTIFICATE_STATUS_LABEL: Record<string, string> = {
  in_stock: 'In stock',
  issued: 'Issued',
  used: 'Used at bind',
  spoiled: 'Spoiled',
  voided: 'Voided',
};

export const MAX_CERTIFICATE_LOAD = 5000;

export interface RiskForm {
  riskType: string;
  description: string;
  regNo: string;
  chassisNo: string;
  engineNo: string;
  make: string;
  model: string;
  yearMade: string;
  sumInsured: string;
}

export const EMPTY_RISK_FORM: RiskForm = {
  riskType: 'vehicle',
  description: '',
  regNo: '',
  chassisNo: '',
  engineNo: '',
  make: '',
  model: '',
  yearMade: '',
  sumInsured: '',
};

/** Returns the first problem with a risk form, or null when it can be saved. */
export function validateRisk(form: RiskForm, line: CertificateLine | null | undefined): string | null {
  if (!form.description.trim()) return 'Describe the risk.';
  if (lineNeedsCertificate(line)) {
    if (form.riskType !== 'vehicle') return 'A product line that needs a certificate needs a vehicle risk.';
    if (!form.chassisNo.trim()) return 'A vehicle needs a chassis number.';
  }
  if (form.yearMade.trim()) {
    const year = Number(form.yearMade);
    if (!Number.isInteger(year) || year < 1950 || year > 2100) return 'Year made must be between 1950 and 2100.';
  }
  if (form.sumInsured.trim()) {
    const sum = Number(form.sumInsured);
    if (!Number.isFinite(sum) || sum < 0) return 'Sum insured cannot be negative.';
  }
  return null;
}

export interface CertificateRange {
  prefix: string;
  from: string;
  to: string;
  width: string;
}

export const EMPTY_CERTIFICATE_RANGE: CertificateRange = { prefix: '', from: '', to: '', width: '8' };

/** Returns the first problem with a stock range, or null. Mirrors ins_load_certificate_range. */
export function validateCertificateRange(range: CertificateRange): string | null {
  const from = Number(range.from);
  const to = Number(range.to);
  const width = Number(range.width);
  if (range.from.trim() === '' || range.to.trim() === '') return 'Enter the first and last serial numbers.';
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0) return 'Serial numbers must be whole numbers, 0 or more.';
  if (to < from) return 'The last serial must be at or after the first.';
  if (to - from + 1 > MAX_CERTIFICATE_LOAD) return `Load at most ${MAX_CERTIFICATE_LOAD} certificates at a time.`;
  if (!Number.isInteger(width) || width < 1 || width > 20) return 'Serial width must be 1 to 20 digits.';
  const sample = `${range.prefix.trim()}${String(to).padStart(width, '0')}`;
  if (sample.length > 40) return 'Serial numbers are too long. Shorten the prefix or the width.';
  return null;
}

/** Example of the first serial in a range, for the confirmation text. */
export function firstSerial(range: CertificateRange): string {
  return `${range.prefix.trim()}${String(Number(range.from)).padStart(Number(range.width) || 1, '0')}`;
}

export function countCertificatesByStatus(rows: { status: string }[]): Record<string, number> {
  const counts: Record<string, number> = { in_stock: 0, issued: 0, used: 0, spoiled: 0, voided: 0 };
  for (const row of rows) counts[row.status] = (counts[row.status] ?? 0) + 1;
  return counts;
}

/** A certificate can be spoiled or voided only while in stock, or issued and not attached to a policy. */
export function canCloseCertificate(cert: { status: string; policy_id: string | null }): boolean {
  return (cert.status === 'in_stock' || cert.status === 'issued') && !cert.policy_id;
}

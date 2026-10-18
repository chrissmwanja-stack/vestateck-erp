import type { Claim, InsClient, Insurer, Policy } from './types';

// Search and filters for the insurance lists. The lists already load every row they show, so
// this narrows them on the page with no extra round trip. Pure functions, no screen code.

/** Lower case and strip accents, so "Müller" is found by "muller" and "KAMPALA" by "kampala". */
const fold = (v: unknown): string =>
  String(v ?? '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');

/**
 * Every word typed must appear somewhere in the fields. Words may match different fields,
 * so "jubilee motor" finds a Jubilee policy on the Motor line. An empty query matches all.
 */
export function matchesText(fields: ReadonlyArray<string | number | null | undefined>, query: string): boolean {
  const words = fold(query).split(/\s+/).filter(Boolean);
  if (words.length === 0) return true;
  const haystack = fields.map(fold).join('\u0000');
  return words.every((w) => haystack.includes(w));
}

/** Distinct id/name pairs from a list of rows, A to Z, for a filter dropdown. */
export function distinctOptions<T>(
  rows: readonly T[],
  idOf: (row: T) => string | null | undefined,
  nameOf: (row: T) => string | null | undefined,
): { id: string; name: string }[] {
  const seen = new Map<string, string>();
  for (const r of rows) {
    const id = idOf(r);
    if (id && !seen.has(id)) seen.set(id, nameOf(r) || id);
  }
  return [...seen].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name));
}

/** How many filters are doing something: not empty, and not 'all' or the given default. */
export function countActive(values: Record<string, string>, defaults: Record<string, string> = {}): number {
  return Object.entries(values).filter(([k, v]) => v !== '' && v !== 'all' && v !== (defaults[k] ?? '')).length;
}

// ---- Policies -------------------------------------------------------------------------------

export interface PolicyFilters {
  text: string;
  insurerId: string;
  productLineId: string;
  /** Expiry on or after this date (yyyy-mm-dd). */
  expiresFrom: string;
  /** Expiry on or before this date (yyyy-mm-dd). */
  expiresTo: string;
}

export const EMPTY_POLICY_FILTERS: PolicyFilters = { text: '', insurerId: '', productLineId: '', expiresFrom: '', expiresTo: '' };

/** Sorting by premium is left out on purpose: amounts in different currencies cannot be ranked. */
export type PolicySort = 'newest' | 'expiry_soonest' | 'expiry_latest' | 'client_az';

export const POLICY_SORT_LABEL: Record<PolicySort, string> = {
  newest: 'Newest first',
  expiry_soonest: 'Expiry, soonest first',
  expiry_latest: 'Expiry, latest first',
  client_az: 'Client, A to Z',
};

export function filterPolicies(policies: Policy[], f: PolicyFilters): Policy[] {
  return policies.filter(
    (p) =>
      matchesText([p.policy_no, p.ins_clients?.bd_clients?.name, p.ins_insurers?.name, p.ins_product_lines?.name], f.text) &&
      (!f.insurerId || p.insurer_id === f.insurerId) &&
      (!f.productLineId || p.product_line_id === f.productLineId) &&
      (!f.expiresFrom || p.expiry_date >= f.expiresFrom) &&
      (!f.expiresTo || p.expiry_date <= f.expiresTo),
  );
}

export function sortPolicies(policies: Policy[], sort: PolicySort): Policy[] {
  const out = [...policies];
  switch (sort) {
    case 'expiry_soonest':
      return out.sort((a, b) => a.expiry_date.localeCompare(b.expiry_date) || a.policy_no.localeCompare(b.policy_no));
    case 'expiry_latest':
      return out.sort((a, b) => b.expiry_date.localeCompare(a.expiry_date) || a.policy_no.localeCompare(b.policy_no));
    case 'client_az':
      return out.sort(
        (a, b) =>
          (a.ins_clients?.bd_clients?.name ?? '').localeCompare(b.ins_clients?.bd_clients?.name ?? '') || a.policy_no.localeCompare(b.policy_no),
      );
    default:
      return out; // already newest first as loaded
  }
}

// ---- Claims ---------------------------------------------------------------------------------

export interface ClaimFilters {
  text: string;
  insurerId: string;
  /** Loss date on or after / on or before (yyyy-mm-dd). */
  lossFrom: string;
  lossTo: string;
}

export const EMPTY_CLAIM_FILTERS: ClaimFilters = { text: '', insurerId: '', lossFrom: '', lossTo: '' };

export function filterClaims(claims: Claim[], f: ClaimFilters): Claim[] {
  return claims.filter(
    (c) =>
      matchesText(
        [c.claim_no, c.ins_policies?.policy_no, c.ins_policies?.ins_clients?.bd_clients?.name, c.loss_description, c.insurer_claim_ref, c.ins_policies?.ins_insurers?.name],
        f.text,
      ) &&
      (!f.insurerId || c.ins_policies?.insurer_id === f.insurerId) &&
      (!f.lossFrom || c.loss_date >= f.lossFrom) &&
      (!f.lossTo || c.loss_date <= f.lossTo),
  );
}

// ---- Clients and insurers -------------------------------------------------------------------

export interface ClientFilters {
  text: string;
  kyc: 'all' | InsClient['kyc_status'];
  risk: 'all' | InsClient['risk_rating'];
  type: 'all' | InsClient['client_type'];
}

export const EMPTY_CLIENT_FILTERS: ClientFilters = { text: '', kyc: 'all', risk: 'all', type: 'all' };

export function filterClients(clients: InsClient[], f: ClientFilters): InsClient[] {
  return clients.filter(
    (c) =>
      matchesText([c.bd_clients?.name, c.tax_id, c.bd_clients?.email, c.bd_clients?.phone], f.text) &&
      (f.kyc === 'all' || c.kyc_status === f.kyc) &&
      (f.risk === 'all' || c.risk_rating === f.risk) &&
      (f.type === 'all' || c.client_type === f.type),
  );
}

export interface InsurerFilters {
  text: string;
  active: 'all' | 'active' | 'inactive';
}

export const EMPTY_INSURER_FILTERS: InsurerFilters = { text: '', active: 'all' };

export function filterInsurers(insurers: Insurer[], f: InsurerFilters): Insurer[] {
  return insurers.filter(
    (i) =>
      matchesText([i.code, i.name, i.contact_name, i.contact_email, i.contact_phone], f.text) &&
      (f.active === 'all' || (f.active === 'active') === i.is_active),
  );
}

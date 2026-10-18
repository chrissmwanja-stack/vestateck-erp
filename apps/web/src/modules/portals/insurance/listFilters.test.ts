import { describe, expect, it } from 'vitest';
import {
  EMPTY_CLAIM_FILTERS, EMPTY_CLIENT_FILTERS, EMPTY_INSURER_FILTERS, EMPTY_POLICY_FILTERS, countActive, distinctOptions, filterClaims, filterClients,
  filterInsurers, filterPolicies, matchesText, sortPolicies,
} from './listFilters';
import type { Claim, InsClient, Insurer, Policy } from './types';

const policy = (over: Record<string, unknown>): Policy => ({
  id: 'p', policy_no: 'POL-00001', status: 'active', client_id: 'c', insurer_id: 'i1', product_line_id: 'l1', inception_date: '2026-01-01', expiry_date: '2026-12-31',
  sum_insured: 0, currency: 'UGX', gross_premium: 1000, commission_amount: 100,
  ins_clients: { bd_clients: { name: 'Acme Ltd' } }, ins_insurers: { name: 'Jubilee' }, ins_product_lines: { name: 'Motor' }, ...over,
}) as unknown as Policy;

describe('matchesText', () => {
  it('matches everything on an empty query', () => {
    expect(matchesText(['a'], '')).toBe(true);
    expect(matchesText([], '   ')).toBe(true);
  });
  it('ignores case and accents', () => {
    expect(matchesText(['Müller & Söhne'], 'muller sohne')).toBe(true);
    expect(matchesText(['KAMPALA'], 'kampala')).toBe(true);
  });
  it('needs every word, which may sit in different fields', () => {
    expect(matchesText(['Jubilee', 'Motor'], 'jubilee motor')).toBe(true);
    expect(matchesText(['Jubilee', 'Motor'], 'jubilee fire')).toBe(false);
  });
  it('copes with missing fields and numbers', () => {
    expect(matchesText([null, undefined, 42], '42')).toBe(true);
    expect(matchesText([null, undefined], 'x')).toBe(false);
  });
  it('does not let a word match across the join of two fields', () => {
    expect(matchesText(['abc', 'def'], 'cd')).toBe(false);
  });
});

describe('distinctOptions and countActive', () => {
  it('lists each id once, A to Z by name, skipping rows with no id', () => {
    const rows = [{ id: 'b', n: 'Zeta' }, { id: 'a', n: 'Alpha' }, { id: 'b', n: 'Zeta' }, { id: null, n: 'x' }];
    expect(distinctOptions(rows, (r) => r.id, (r) => r.n)).toEqual([{ id: 'a', name: 'Alpha' }, { id: 'b', name: 'Zeta' }]);
  });
  it('counts filters that are doing something', () => {
    expect(countActive({ text: '', kyc: 'all', insurer: '' })).toBe(0);
    expect(countActive({ text: 'x', kyc: 'pending', insurer: '' })).toBe(2);
    expect(countActive({ show: 'open' }, { show: 'open' })).toBe(0);
    expect(countActive({ show: 'closed' }, { show: 'open' })).toBe(1);
  });
});

describe('filterPolicies and sortPolicies', () => {
  const list = [
    policy({ id: '1', policy_no: 'POL-00001', expiry_date: '2026-03-31' }),
    policy({ id: '2', policy_no: 'POL-00002', insurer_id: 'i2', ins_insurers: { name: 'Britam' }, product_line_id: 'l2', ins_product_lines: { name: 'Fire' }, expiry_date: '2026-11-30', ins_clients: { bd_clients: { name: 'Zed Co' } } }),
    policy({ id: '3', policy_no: 'POL-00003', expiry_date: '2026-06-30', ins_clients: { bd_clients: { name: 'Bravo Ltd' } } }),
  ];
  const ids = (rows: Policy[]) => rows.map((p) => p.id);

  it('searches policy number, client, insurer and product', () => {
    expect(ids(filterPolicies(list, { ...EMPTY_POLICY_FILTERS, text: '00002' }))).toEqual(['2']);
    expect(ids(filterPolicies(list, { ...EMPTY_POLICY_FILTERS, text: 'zed' }))).toEqual(['2']);
    expect(ids(filterPolicies(list, { ...EMPTY_POLICY_FILTERS, text: 'britam fire' }))).toEqual(['2']);
    expect(ids(filterPolicies(list, { ...EMPTY_POLICY_FILTERS, text: 'jubilee motor' }))).toEqual(['1', '3']);
  });
  it('filters by insurer, product and an inclusive expiry window', () => {
    expect(ids(filterPolicies(list, { ...EMPTY_POLICY_FILTERS, insurerId: 'i2' }))).toEqual(['2']);
    expect(ids(filterPolicies(list, { ...EMPTY_POLICY_FILTERS, productLineId: 'l1' }))).toEqual(['1', '3']);
    expect(ids(filterPolicies(list, { ...EMPTY_POLICY_FILTERS, expiresFrom: '2026-06-30', expiresTo: '2026-11-30' }))).toEqual(['2', '3']);
  });
  it('combines filters', () => {
    expect(ids(filterPolicies(list, { ...EMPTY_POLICY_FILTERS, text: 'ltd', insurerId: 'i1', expiresTo: '2026-04-01' }))).toEqual(['1']);
  });
  it('sorts without changing the list it was given', () => {
    const before = ids(list);
    expect(ids(sortPolicies(list, 'expiry_soonest'))).toEqual(['1', '3', '2']);
    expect(ids(sortPolicies(list, 'expiry_latest'))).toEqual(['2', '3', '1']);
    expect(ids(sortPolicies(list, 'client_az'))).toEqual(['1', '3', '2']);
    expect(ids(sortPolicies(list, 'newest'))).toEqual(before);
    expect(ids(list)).toEqual(before);
  });
});

describe('filterClaims', () => {
  const claim = (over: Record<string, unknown>): Claim => ({
    id: 'c', claim_no: 'CLM-00001', policy_id: 'p', status: 'notified', loss_date: '2026-05-10', loss_description: 'Rear-end collision on Jinja Road', insurer_claim_ref: null,
    ins_policies: { policy_no: 'POL-00001', currency: 'UGX', insurer_id: 'i1', ins_insurers: { name: 'Jubilee' }, ins_clients: { bd_clients: { name: 'Acme Ltd' } } }, ...over,
  }) as unknown as Claim;
  const list = [
    claim({ id: '1' }),
    claim({ id: '2', claim_no: 'CLM-00002', loss_date: '2026-08-01', loss_description: 'Warehouse fire', insurer_claim_ref: 'BRT/778', ins_policies: { policy_no: 'POL-00009', currency: 'UGX', insurer_id: 'i2', ins_insurers: { name: 'Britam' }, ins_clients: { bd_clients: { name: 'Zed Co' } } } }),
  ];
  const ids = (rows: Claim[]) => rows.map((c) => c.id);
  it('searches claim, policy, client, description, insurer and the insurer reference', () => {
    expect(ids(filterClaims(list, { ...EMPTY_CLAIM_FILTERS, text: 'jinja' }))).toEqual(['1']);
    expect(ids(filterClaims(list, { ...EMPTY_CLAIM_FILTERS, text: 'brt/778' }))).toEqual(['2']);
    expect(ids(filterClaims(list, { ...EMPTY_CLAIM_FILTERS, text: 'pol-00009' }))).toEqual(['2']);
    expect(ids(filterClaims(list, { ...EMPTY_CLAIM_FILTERS, text: 'zed' }))).toEqual(['2']);
  });
  it('filters by insurer and loss date window', () => {
    expect(ids(filterClaims(list, { ...EMPTY_CLAIM_FILTERS, insurerId: 'i2' }))).toEqual(['2']);
    expect(ids(filterClaims(list, { ...EMPTY_CLAIM_FILTERS, lossFrom: '2026-06-01' }))).toEqual(['2']);
    expect(ids(filterClaims(list, { ...EMPTY_CLAIM_FILTERS, lossTo: '2026-06-01' }))).toEqual(['1']);
  });
});

describe('filterClients and filterInsurers', () => {
  const client = (over: Record<string, unknown>): InsClient => ({
    id: 'c', client_id: 'b', client_type: 'corporate', tax_id: '1000012345', risk_rating: 'medium', kyc_status: 'pending',
    bd_clients: { name: 'Acme Ltd', email: 'info@acme.test', phone: '+256700000001' }, ...over,
  }) as unknown as InsClient;
  const clients = [
    client({ id: '1' }),
    client({ id: '2', client_type: 'individual', tax_id: null, risk_rating: 'high', kyc_status: 'verified', bd_clients: { name: 'Jane Doe', email: null, phone: '0772123456' } }),
  ];
  it('searches name, tax id, email and phone', () => {
    const ids = (t: string) => filterClients(clients, { ...EMPTY_CLIENT_FILTERS, text: t }).map((c) => c.id);
    expect(ids('jane')).toEqual(['2']);
    expect(ids('1000012345')).toEqual(['1']);
    expect(ids('acme.test')).toEqual(['1']);
    expect(ids('772123')).toEqual(['2']);
  });
  it('filters by KYC, risk and type', () => {
    expect(filterClients(clients, { ...EMPTY_CLIENT_FILTERS, kyc: 'verified' }).map((c) => c.id)).toEqual(['2']);
    expect(filterClients(clients, { ...EMPTY_CLIENT_FILTERS, risk: 'high' }).map((c) => c.id)).toEqual(['2']);
    expect(filterClients(clients, { ...EMPTY_CLIENT_FILTERS, type: 'corporate' }).map((c) => c.id)).toEqual(['1']);
    expect(filterClients(clients, { ...EMPTY_CLIENT_FILTERS, kyc: 'expired' })).toEqual([]);
  });
  it('searches insurers and filters by active', () => {
    const insurers = [
      { id: '1', code: 'JUB', name: 'Jubilee', contact_name: 'Sam', contact_email: null, contact_phone: null, is_active: true },
      { id: '2', code: 'BRT', name: 'Britam', contact_name: null, contact_email: 'a@britam.test', contact_phone: null, is_active: false },
    ] as unknown as Insurer[];
    expect(filterInsurers(insurers, { ...EMPTY_INSURER_FILTERS, text: 'sam' }).map((i) => i.id)).toEqual(['1']);
    expect(filterInsurers(insurers, { ...EMPTY_INSURER_FILTERS, text: 'britam.test' }).map((i) => i.id)).toEqual(['2']);
    expect(filterInsurers(insurers, { ...EMPTY_INSURER_FILTERS, active: 'inactive' }).map((i) => i.id)).toEqual(['2']);
    expect(filterInsurers(insurers, { ...EMPTY_INSURER_FILTERS, active: 'active' }).map((i) => i.id)).toEqual(['1']);
  });
});

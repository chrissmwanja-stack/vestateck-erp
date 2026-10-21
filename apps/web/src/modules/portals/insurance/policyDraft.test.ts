import { describe, expect, it } from 'vitest';
import { draftUpdate, type PolicyDraftForm } from './policyDraft';

const form: PolicyDraftForm = {
  clientId: 'c1', insurerId: 'i1', productLineId: 'p1', branchId: 'org1', agentId: 'ag1',
  inception: '2026-10-01', expiry: '2027-09-30',
  sumInsured: '5000000', currency: 'UGX', grossPremium: '250000.50', commissionRatePct: '12.5', riskDescription: '  ', notes: ' renewal ',
};

describe('draftUpdate', () => {
  it('writes every editable field of a draft with no saved insurer shares', () => {
    expect(draftUpdate(form, false)).toEqual({
      client_id: 'c1', insurer_id: 'i1', product_line_id: 'p1', branch_id: 'org1', agent_id: 'ag1',
      inception_date: '2026-10-01', expiry_date: '2027-09-30',
      sum_insured: 5000000, currency: 'UGX', gross_premium: 250000.5, commission_rate_pct: 12.5, risk_description: null, notes: 'renewal',
    });
  });
  it('leaves the insurer and commission rate to the saved configuration when there is one', () => {
    const patch = draftUpdate(form, true);
    expect(patch).not.toHaveProperty('insurer_id');
    expect(patch).not.toHaveProperty('commission_rate_pct');
    expect(patch.gross_premium).toBe(250000.5);
  });
  it('leaves the client and product line alone while risks are linked, and still writes the rest', () => {
    const patch = draftUpdate(form, false, true);
    expect(patch).not.toHaveProperty('client_id');
    expect(patch).not.toHaveProperty('product_line_id');
    expect(patch).toMatchObject({ gross_premium: 250000.5, insurer_id: 'i1', notes: 'renewal' });
  });
  it('writes the client and product line when no risk is linked', () => {
    expect(draftUpdate(form, false, false)).toMatchObject({ client_id: 'c1', product_line_id: 'p1' });
    expect(draftUpdate(form, true)).toMatchObject({ client_id: 'c1', product_line_id: 'p1' });
  });
  it('treats blank numbers as zero', () => {
    expect(draftUpdate({ ...form, sumInsured: '', grossPremium: '' }, false)).toMatchObject({ sum_insured: 0, gross_premium: 0 });
  });
  it('saves empty branch and agent selections as nulls', () => {
    expect(draftUpdate({ ...form, branchId: '', agentId: '' }, false)).toMatchObject({ branch_id: null, agent_id: null });
  });
});

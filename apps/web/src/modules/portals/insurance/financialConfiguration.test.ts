import { describe, expect, it } from 'vitest';
import {
  configurationProblems,
  type InsurerShare,
  type PolicyCharge,
} from './financialConfiguration';
const share = (over: Partial<InsurerShare> = {}): InsurerShare => ({
  insurer_id: 'a',
  is_lead: true,
  share_pct: 100,
  commission_rate_pct: 10,
  insurer_policy_no: null,
  reviewed: true,
  ...over,
});
const fee = (over: Partial<PolicyCharge> = {}): PolicyCharge => ({
  kind: 'broker_fee',
  description: 'Broker fee',
  amount: 50,
  recipient_mode: 'broker',
  recipient_insurer_id: null,
  vat_mode: 'not_calculated',
  vat_rate_pct: null,
  income_gl_account_id: 'revenue',
  reviewed: true,
  fee_class: 'insurance_brokerage',
  fee_class_reason: null,
  ...over,
});
const taxable = (over: Partial<PolicyCharge> = {}): PolicyCharge =>
  fee({
    fee_class: 'other_taxable_service',
    fee_class_reason: 'Separate risk-survey consultancy, not placement work',
    vat_mode: 'exclusive',
    ...over,
  });
describe('additive financial configuration UI validation', () => {
  it('preserves empty configuration as the existing single-insurer workflow', () =>
    expect(configurationProblems([], [])).toEqual([]));
  it('requires exactly 100% and exactly one lead', () => {
    expect(configurationProblems([share({ share_pct: 90 })], [])).toContain(
      'Insurer shares must total exactly 100%.',
    );
    expect(configurationProblems([share({ is_lead: false })], [])).toContain(
      'Choose exactly one lead insurer.',
    );
  });
  it('accepts exact four-decimal allocation percentages', () => {
    expect(
      configurationProblems(
        [
          share({ share_pct: 33.3333 }),
          share({ insurer_id: 'b', is_lead: false, share_pct: 33.3333 }),
          share({ insurer_id: 'c', is_lead: false, share_pct: 33.3334 }),
        ],
        [],
      ),
    ).toEqual([]);
  });
  it('rejects duplicate insurers', () =>
    expect(
      configurationProblems(
        [share({ share_pct: 50 }), share({ is_lead: false, share_pct: 50 })],
        [],
      ),
    ).toContain('Each insurer may appear only once.'));
  it('requires explicit participating recipients for insurer-specific charges', () => {
    expect(
      configurationProblems(
        [share()],
        [
          fee({
            kind: 'insurer_pass_through',
            recipient_mode: 'one_insurer',
            recipient_insurer_id: 'other',
          }),
        ],
      ),
    ).toContain(
      'Choose a participating insurer for each insurer-specific charge.',
    );
  });
  it('allows VAT not calculated without silently assuming exemption or a tax rate', () =>
    expect(configurationProblems([share()], [fee()])).toEqual([]));
  it('requires an explicit VAT rate on a pass-through charge with VAT on', () =>
    expect(
      configurationProblems(
        [share()],
        [
          fee({
            kind: 'insurer_pass_through',
            recipient_mode: 'all_insurers',
            fee_class: null,
            vat_mode: 'exclusive',
          }),
        ],
      ),
    ).toContain(
      'Enter the applicable VAT rate; no statutory rate is assumed.',
    ));
  it('requires every broker fee to be classified', () =>
    expect(
      configurationProblems([share()], [fee({ fee_class: null })]),
    ).toContain(
      'Choose what kind of supply each broker fee is (insurance brokerage or other taxable service).',
    ));
  it('does not require a class on a pass-through charge', () =>
    expect(
      configurationProblems(
        [share()],
        [
          fee({
            kind: 'insurer_pass_through',
            recipient_mode: 'all_insurers',
            fee_class: null,
          }),
        ],
      ),
    ).toEqual([]));
  it('refuses VAT on an insurance brokerage fee', () => {
    const msg =
      'An insurance brokerage fee is VAT-exempt and cannot carry VAT. If it is a separate taxable service, classify it as one.';
    expect(
      configurationProblems([share()], [fee({ vat_mode: 'exclusive' })]),
    ).toContain(msg);
    expect(
      configurationProblems([share()], [fee({ vat_rate_pct: 18 })]),
    ).toContain(msg);
  });
  it('requires a reason of at least 20 characters for a taxable service', () => {
    const msg =
      'Give a reason of at least 20 characters for treating a fee as a taxable service.';
    expect(
      configurationProblems([share()], [taxable({ fee_class_reason: null })]),
    ).toContain(msg);
    expect(
      configurationProblems(
        [share()],
        [taxable({ fee_class_reason: '   too short   ' })],
      ),
    ).toContain(msg);
    expect(configurationProblems([share()], [taxable()])).toEqual([]);
  });
  it('lets a taxable service leave the rate blank for the approved standard rate', () =>
    expect(
      configurationProblems([share()], [taxable({ vat_rate_pct: null })]),
    ).toEqual([]));
  it('still rejects an impossible typed rate on a taxable service', () =>
    expect(
      configurationProblems([share()], [taxable({ vat_rate_pct: 150 })]),
    ).toContain(
      'Enter the applicable VAT rate; no statutory rate is assumed.',
    ));
  it('requires a broker-income account for positive fees but permits explicit zero', () => {
    expect(
      configurationProblems([share()], [fee({ income_gl_account_id: null })]),
    ).toContain('Choose an income GL account for each broker fee.');
    expect(
      configurationProblems(
        [share()],
        [fee({ amount: 0, income_gl_account_id: null })],
      ),
    ).toEqual([]);
  });
  it('allows blank renewal charge amounts to be saved for subsequent review', () =>
    expect(
      configurationProblems(
        [share()],
        [fee({ amount: null, reviewed: false })],
      ),
    ).toEqual([]));
});

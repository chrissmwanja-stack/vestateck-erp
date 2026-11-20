import { describe, expect, it } from 'vitest';
import {
  statutoryLines,
  statutoryProblems,
  type PolicyCharge,
  type StatutoryState,
} from './financialConfiguration';

// The rules under test belong to the panel but not to the DOM, so they live in
// financialConfiguration.ts and are tested here. What matters is that the screen
// tells a manager the same thing the database will enforce -- a warning shown in the
// wrong state is worse than none, because it trains people to ignore it.

const state = (over: Partial<StatutoryState> = {}): StatutoryState => ({
  ack: null,
  acknowledged: false,
  acknowledged_total: null,
  priced_total: 0,
  priced_count: 0,
  enforcement: 'required',
  ...over,
});

const details = (over: Partial<Parameters<typeof statutoryProblems>[0]> = {}) => ({
  status: 'draft',
  statutory: state(),
  enforcement: 'required' as const,
  ...over,
});

describe('statutoryProblems', () => {
  it('says nothing when the company has not turned enforcement on', () => {
    expect(
      statutoryProblems(
        details({ statutory: state({ enforcement: 'advisory' }), enforcement: 'advisory' }),
      ),
    ).toEqual([]);
  });

  it('says nothing when nothing is priced, because the catalogue may genuinely be empty', () => {
    // The screen cannot know whether the catalogue prices anything for this company;
    // the bind re-checks. Telling a manager to price something that does not exist
    // would be a false alarm on every policy.
    expect(statutoryProblems(details())).toEqual([]);
  });

  it('asks for an acknowledgement when charges are priced but not acknowledged', () => {
    const p = statutoryProblems(
      details({ statutory: state({ priced_count: 1, priced_total: 500 }) }),
    );
    expect(p).toHaveLength(1);
    expect(p[0]).toMatch(/priced but not acknowledged/i);
  });

  it('is satisfied by an acknowledgement that still matches the prices', () => {
    expect(
      statutoryProblems(
        details({
          statutory: state({
            priced_count: 1,
            priced_total: 500,
            acknowledged: true,
            acknowledged_total: 500,
          }),
        }),
      ),
    ).toEqual([]);
  });

  it('catches a stale acknowledgement -- the case a rate change creates', () => {
    const p = statutoryProblems(
      details({
        statutory: state({
          priced_count: 1,
          priced_total: 1000,
          acknowledged: true,
          acknowledged_total: 500,
        }),
      }),
    );
    expect(p[0]).toMatch(/changed after they were acknowledged/i);
  });

  it('does not warn on a bound policy, where the question is settled', () => {
    expect(
      statutoryProblems(
        details({ status: 'active', statutory: state({ priced_count: 1, priced_total: 500 }) }),
      ),
    ).toEqual([]);
  });

  it('falls back to advisory when an older API response has no statutory block', () => {
    // The panel must not start warning merely because the deployment and the
    // database are briefly out of step.
    expect(statutoryProblems({ status: 'draft', statutory: null })).toEqual([]);
  });
});

describe('statutoryLines', () => {
  const charge = (over: Partial<PolicyCharge> = {}): PolicyCharge => ({
    kind: 'insurer_pass_through',
    description: 'Insurance Training Levy',
    amount: 500,
    recipient_mode: 'all_insurers',
    recipient_insurer_id: null,
    vat_mode: 'not_calculated',
    vat_rate_pct: null,
    income_gl_account_id: null,
    reviewed: true,
    ...over,
  });

  it('includes only lines that came from the catalogue', () => {
    const manual = charge({ description: 'Negotiated fee', kind: 'broker_fee' });
    const statutory = charge({ catalogue_id: 'c1', charge_class: 'statutory_levy' });
    expect(statutoryLines([manual, statutory])).toEqual([statutory]);
  });

  it('returns nothing when no line carries a catalogue id', () => {
    expect(statutoryLines([charge()])).toEqual([]);
  });
});

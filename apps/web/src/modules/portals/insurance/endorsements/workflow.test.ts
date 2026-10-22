// Pure pieces of the endorsement workflow: term/changes shaping, status
// tones, signed money formatting, and the live-status helper. The heavy math
// is server-side; these tests pin the client contract.
import { describe, expect, it } from 'vitest';
import {
  buildChanges, buildTerms, formatSigned, isLive, statusTone,
} from './workflow';

describe('buildTerms', () => {
  it('keeps only drafts with a signed delta and trims it', () => {
    expect(
      buildTerms([
        { insurer_id: 'u1', agreed_delta: ' 120000 ' },
        { insurer_id: 'u2', agreed_delta: '' },
        { insurer_id: 'u3', agreed_delta: '   ' },
      ]),
    ).toEqual([{ insurer_id: 'u1', agreed_delta: '120000' }]);
  });

  it('keeps negative deltas (return premiums)', () => {
    expect(buildTerms([{ insurer_id: 'u1', agreed_delta: '-45000' }])).toEqual([
      { insurer_id: 'u1', agreed_delta: '-45000' },
    ]);
  });

  it('returns an empty terms list when everything is blank (descriptive-only)', () => {
    expect(buildTerms([{ insurer_id: 'u1', agreed_delta: '' }])).toEqual([]);
  });
});

describe('buildChanges', () => {
  it('drops empty fields', () => {
    expect(buildChanges({ sum_insured: '', risk_description: '  ', notes: '' })).toEqual({});
  });

  it('sends a numeric sum insured and trimmed text fields', () => {
    expect(buildChanges({ sum_insured: ' 5000000 ', risk_description: ' Fire add-on ', notes: ' client asked ' })).toEqual({
      sum_insured: 5000000,
      risk_description: 'Fire add-on',
      notes: 'client asked',
    });
  });

  it('refuses a non-positive sum insured', () => {
    expect(() => buildChanges({ sum_insured: '0' })).toThrow(/positive/i);
    expect(() => buildChanges({ sum_insured: '-5' })).toThrow(/positive/i);
    expect(() => buildChanges({ sum_insured: 'abc' })).toThrow(/positive/i);
  });
});

describe('statusTone', () => {
  it('maps posted to success, live states to warning, rejected to error', () => {
    expect(statusTone('posted')).toBe('success');
    expect(statusTone('proposed')).toBe('warning');
    expect(statusTone('prepared')).toBe('warning');
    expect(statusTone('posting')).toBe('warning');
    expect(statusTone('rejected')).toBe('error');
    expect(statusTone('withdrawn')).toBe('default');
  });
});

describe('formatSigned', () => {
  it('formats positive amounts with currency and thousands separators', () => {
    expect(formatSigned(1234500, 'UGX')).toBe('UGX 1,234,500.00');
  });

  it('prefixes a minus for negative amounts (return premium)', () => {
    expect(formatSigned(-45000, 'UGX')).toBe('-UGX 45,000.00');
  });

  it('treats null and undefined as zero', () => {
    expect(formatSigned(null, 'USD')).toBe('USD 0.00');
    expect(formatSigned(undefined, 'USD')).toBe('USD 0.00');
  });
});

describe('isLive', () => {
  it('treats proposed, prepared and posting as live; terminal states as not', () => {
    expect(isLive('proposed')).toBe(true);
    expect(isLive('prepared')).toBe(true);
    expect(isLive('posting')).toBe(true);
    expect(isLive('posted')).toBe(false);
    expect(isLive('rejected')).toBe(false);
    expect(isLive('withdrawn')).toBe(false);
  });
});

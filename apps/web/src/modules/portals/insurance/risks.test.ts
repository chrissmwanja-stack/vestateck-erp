import { describe, expect, it } from 'vitest';
import {
  EMPTY_RISK_FORM, canCloseCertificate, countCertificatesByStatus, firstSerial, validateCertificateRange, validateRisk,
  type CertificateRange, type RiskForm,
} from './risks';

const base: RiskForm = { ...EMPTY_RISK_FORM, description: 'Toyota Hilux pickup', chassisNo: 'CH-1' };
const range = (over: Partial<CertificateRange>): CertificateRange => ({ prefix: 'MC-', from: '1', to: '10', width: '4', ...over });

describe('validateRisk', () => {
  it('needs a description', () => {
    expect(validateRisk({ ...base, description: '  ' }, 'PROP')).toMatch(/Describe/);
  });

  it('requires a vehicle and a chassis number on a motor line', () => {
    expect(validateRisk({ ...base, riskType: 'property' }, 'MOTOR')).toMatch(/vehicle risk/);
    expect(validateRisk({ ...base, chassisNo: ' ' }, 'MOTOR')).toMatch(/chassis/);
    expect(validateRisk(base, 'MOTOR')).toBeNull();
  });

  it('allows a property risk with no chassis on a non-motor line', () => {
    expect(validateRisk({ ...base, riskType: 'property', chassisNo: '' }, 'PROP')).toBeNull();
  });

  it('checks year and sum insured when given', () => {
    expect(validateRisk({ ...base, yearMade: '1800' }, 'MOTOR')).toMatch(/Year/);
    expect(validateRisk({ ...base, yearMade: '2019.5' }, 'MOTOR')).toMatch(/Year/);
    expect(validateRisk({ ...base, sumInsured: '-1' }, 'MOTOR')).toMatch(/negative/);
    expect(validateRisk({ ...base, yearMade: '2019', sumInsured: '1000000' }, 'MOTOR')).toBeNull();
  });
});

describe('validateCertificateRange', () => {
  it('accepts a normal range', () => {
    expect(validateCertificateRange(range({}))).toBeNull();
  });

  it('rejects an empty range and a backwards range', () => {
    expect(validateCertificateRange(range({ from: '' }))).toMatch(/first and last/);
    expect(validateCertificateRange(range({ from: '10', to: '9' }))).toMatch(/at or after/);
  });

  it('rejects more than 5000 certificates in one load', () => {
    expect(validateCertificateRange(range({ from: '0', to: '4999' }))).toBeNull();
    expect(validateCertificateRange(range({ from: '0', to: '5000' }))).toMatch(/at most 5000/);
  });

  it('rejects negative or fractional numbers and a bad width', () => {
    expect(validateCertificateRange(range({ from: '-1' }))).toMatch(/0 or more/);
    expect(validateCertificateRange(range({ from: '1.5' }))).toMatch(/whole numbers/);
    expect(validateCertificateRange(range({ width: '0' }))).toMatch(/1 to 20/);
  });

  it('rejects serials longer than 40 characters', () => {
    expect(validateCertificateRange(range({ prefix: 'X'.repeat(38), to: '100', width: '4' }))).toMatch(/too long/);
  });
});

describe('certificate helpers', () => {
  it('shows the first serial with padding', () => {
    expect(firstSerial(range({ prefix: 'MC-', from: '7', width: '4' }))).toBe('MC-0007');
  });

  it('counts every status, including zero', () => {
    expect(countCertificatesByStatus([{ status: 'in_stock' }, { status: 'in_stock' }, { status: 'used' }])).toEqual({
      in_stock: 2, issued: 0, used: 1, spoiled: 0, voided: 0,
    });
  });

  it('only closes a certificate in stock, or issued and not attached', () => {
    expect(canCloseCertificate({ status: 'in_stock', policy_id: null })).toBe(true);
    expect(canCloseCertificate({ status: 'issued', policy_id: null })).toBe(true);
    expect(canCloseCertificate({ status: 'issued', policy_id: 'p1' })).toBe(false);
    expect(canCloseCertificate({ status: 'used', policy_id: 'p1' })).toBe(false);
  });
});

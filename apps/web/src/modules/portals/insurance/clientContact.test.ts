import { describe, expect, it } from 'vitest';
import { contactPatch, contactToForm, validateClientContact } from './clientContact';

const orig = { name: 'Acme Ltd', email: 'info@acme.test', phone: null };

describe('validateClientContact', () => {
  it('accepts a normal client', () => {
    expect(validateClientContact({ name: 'Acme Ltd', email: 'info@acme.test', phone: '+256 700 000000' })).toEqual({});
  });
  it('requires a name', () => {
    expect(validateClientContact({ name: '   ', email: '', phone: '' }).name).toBeTruthy();
  });
  it('lets email and phone be blank', () => {
    expect(validateClientContact({ name: 'A', email: '', phone: '' })).toEqual({});
  });
  it('rejects a malformed email', () => {
    for (const email of ['acme', 'a@b', 'a b@c.com', '@acme.test']) {
      expect(validateClientContact({ name: 'A', email, phone: '' }).email).toBeTruthy();
    }
  });
  it('accepts common Ugandan phone formats', () => {
    for (const phone of ['0700 000 000', '+256700000000', '+256-700-000-000', '(041) 4231231', '0414231231']) {
      expect(validateClientContact({ name: 'A', email: '', phone }).phone).toBeUndefined();
    }
  });
  it('rejects letters and too-short numbers', () => {
    for (const phone of ['call me', '12345', '+256 7000 abc']) {
      expect(validateClientContact({ name: 'A', email: '', phone }).phone).toBeTruthy();
    }
  });
  it('caps the name length', () => {
    expect(validateClientContact({ name: 'x'.repeat(201), email: '', phone: '' }).name).toBeTruthy();
  });
});

describe('contactPatch', () => {
  it('is empty when nothing changed', () => {
    expect(contactPatch(orig, contactToForm(orig))).toEqual({});
  });
  it('returns only the changed fields, trimmed', () => {
    expect(contactPatch(orig, { name: ' Acme Limited ', email: 'info@acme.test', phone: ' 0700000000 ' })).toEqual({ name: 'Acme Limited', phone: '0700000000' });
  });
  it('stores a cleared email or phone as null', () => {
    expect(contactPatch(orig, { name: 'Acme Ltd', email: '  ', phone: '' })).toEqual({ email: null });
  });
  it('treats blank and null as the same', () => {
    expect(contactPatch({ name: 'A', email: '', phone: null }, { name: 'A', email: '', phone: '' })).toEqual({});
  });
});

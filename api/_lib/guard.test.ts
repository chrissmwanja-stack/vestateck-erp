import { describe, expect, it, vi } from 'vitest';
import { bodyTooLarge, clean, clientIp, createLimiter, MAX_BODY_BYTES } from './guard';
import clientErrors from '../client-errors';
import cspReport from '../csp-report';

function fakeRes() {
  const r = { code: 0, body: undefined as unknown, ended: false } as {
    code: number; body: unknown; ended: boolean;
    status(c: number): typeof r; json(b: unknown): void; end(): void;
  };
  r.status = (c) => { r.code = c; return r; };
  r.json = (b) => { r.body = b; r.ended = true; };
  r.end = () => { r.ended = true; };
  return r;
}

describe('clean', () => {
  it('strips newlines and control characters so log lines cannot be forged', () => {
    expect(clean('a\nb\r\nc\u0000d')).toBe('a b  c d');
  });
  it('truncates', () => {
    expect(clean('x'.repeat(1000), 10)).toBe('x'.repeat(10));
  });
  it('stringifies objects and survives circular ones', () => {
    expect(clean({ a: 1 })).toBe('{"a":1}');
    const o: Record<string, unknown> = {};
    o.self = o;
    expect(typeof clean(o)).toBe('string');
  });
  it('returns undefined for null/undefined', () => {
    expect(clean(undefined)).toBeUndefined();
    expect(clean(null)).toBeUndefined();
  });
});

describe('clientIp / bodyTooLarge', () => {
  it('uses the first x-forwarded-for hop', () => {
    expect(clientIp({ headers: { 'x-forwarded-for': '1.2.3.4, 5.6.7.8' } })).toBe('1.2.3.4');
  });
  it('falls back to unknown', () => {
    expect(clientIp({})).toBe('unknown');
  });
  it('flags oversized bodies by content-length', () => {
    expect(bodyTooLarge({ headers: { 'content-length': String(MAX_BODY_BYTES + 1) } })).toBe(true);
    expect(bodyTooLarge({ headers: { 'content-length': '100' } })).toBe(false);
    expect(bodyTooLarge({})).toBe(false);
  });
});

describe('createLimiter', () => {
  it('allows up to max per window then refuses, then resets', () => {
    let t = 0;
    const l = createLimiter({ windowMs: 1000, max: 2, now: () => t });
    expect([l.allow('k'), l.allow('k'), l.allow('k')]).toEqual([true, true, false]);
    t = 1500;
    expect(l.allow('k')).toBe(true);
  });
  it('never tracks more than maxKeys live keys (rotating keys cannot grow memory)', () => {
    const l = createLimiter({ windowMs: 60_000, max: 5, maxKeys: 3, now: () => 0 });
    expect(l.allow('a')).toBe(true);
    expect(l.allow('b')).toBe(true);
    expect(l.allow('c')).toBe(true);
    expect(l.allow('d')).toBe(false);
    expect(l.size()).toBe(3);
  });
  it('evicts expired keys to make room', () => {
    let t = 0;
    const l = createLimiter({ windowMs: 1000, max: 5, maxKeys: 2, now: () => t });
    l.allow('a'); l.allow('b');
    t = 2000;
    expect(l.allow('c')).toBe(true);
    expect(l.size()).toBeLessThanOrEqual(2);
  });
});

describe('/api/client-errors', () => {
  it('405 on GET, 413 when oversized, 204 on a normal report', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    let r = fakeRes(); clientErrors({ method: 'GET' }, r); expect(r.code).toBe(405);
    r = fakeRes(); clientErrors({ method: 'POST', headers: { 'content-length': '999999' } }, r); expect(r.code).toBe(413);
    r = fakeRes(); clientErrors({ method: 'POST', headers: { 'x-forwarded-for': '9.9.9.1' }, body: { message: 'boom' } }, r);
    expect(r.code).toBe(204);
    expect(spy).toHaveBeenCalledTimes(1);
    spy.mockRestore();
  });
  it('logs a single line even when the message contains newlines', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    clientErrors({ method: 'POST', headers: { 'x-forwarded-for': '9.9.9.2' }, body: { message: 'a\n[client-error] forged' } }, fakeRes());
    expect(String(spy.mock.calls[0][1])).not.toMatch(/\n/);
    spy.mockRestore();
  });
  it('stops logging after the per-IP limit but still answers 204', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    let last = 0;
    for (let i = 0; i < 50; i++) {
      const r = fakeRes();
      clientErrors({ method: 'POST', headers: { 'x-forwarded-for': '9.9.9.3' }, body: { message: 'x' } }, r);
      last = r.code;
    }
    expect(last).toBe(204);
    expect(spy.mock.calls.length).toBe(20);
    spy.mockRestore();
  });
});

describe('/api/csp-report', () => {
  it('rotating the violation key from one IP cannot exceed the per-IP limit', () => {
    const spy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    for (let i = 0; i < 300; i++) {
      cspReport({ method: 'POST', headers: { 'x-forwarded-for': '8.8.8.8' }, body: { 'csp-report': { 'blocked-uri': `https://e${i}.test` } } }, fakeRes());
    }
    expect(spy.mock.calls.length).toBe(100);
    spy.mockRestore();
  });
  it('always 204 and only whitelisted fields are logged', () => {
    const spy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const r = fakeRes();
    cspReport({ method: 'POST', headers: { 'x-forwarded-for': '8.8.4.4' }, body: { 'csp-report': { 'blocked-uri': 'x', evil: 'injected' } } }, r);
    expect(r.code).toBe(204);
    expect(String(spy.mock.calls[0][1])).not.toContain('injected');
    spy.mockRestore();
  });
});

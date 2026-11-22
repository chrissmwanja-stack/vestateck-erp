import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  BUSINESS_TIME_ZONE,
  addDaysIso,
  addMonthsIso,
  addYearsIso,
  businessDateOf,
  businessMonthStart,
  businessToday,
  businessTodayDate,
  businessYearStart,
  businessNowLocalInput,
  businessMonth,
  businessLocalInputOf,
  businessLocalInputToIso,
  BUSINESS_UTC_OFFSET,
} from './businessDate';

const at = (iso: string) => new Date(iso);

describe('business day (Africa/Kampala)', () => {
  it('is Kampala', () => expect(BUSINESS_TIME_ZONE).toBe('Africa/Kampala'));

  it('is still the previous day at 20:59 UTC and the next day from 21:00 UTC', () => {
    expect(businessToday(at('2026-11-21T20:59:59Z'))).toBe('2026-11-21');
    expect(businessToday(at('2026-11-21T21:00:00Z'))).toBe('2026-11-22');
  });

  it('is ahead of UTC across a month and a year boundary', () => {
    expect(businessToday(at('2026-11-30T22:00:00Z'))).toBe('2026-12-01');
    expect(businessToday(at('2026-12-31T21:30:00Z'))).toBe('2027-01-01');
  });

  it('dates a timestamp by the Kampala day, as ins_local_date() does', () => {
    // The 1 a.m. case from the migration: bound 01:00 on the 5th is the 5th, not the 4th.
    expect(businessDateOf('2026-11-04T22:00:00Z')).toBe('2026-11-05');
    expect(businessDateOf('2026-11-05T02:59:00+03:00')).toBe('2026-11-05');
    expect(businessDateOf(Date.UTC(2026, 10, 5, 21, 0))).toBe('2026-11-06');
  });

  it('rejects an invalid instant', () => {
    expect(() => businessDateOf('not a date')).toThrow(RangeError);
  });

  it('finds the start of the month and the year', () => {
    expect(businessMonthStart(at('2026-11-30T21:30:00Z'))).toBe('2026-12-01');
    expect(businessYearStart(at('2026-12-31T21:30:00Z'))).toBe('2027-01-01');
    expect(businessYearStart(at('2026-06-15T10:00:00Z'))).toBe('2026-01-01');
  });
});

describe('datetime-local and month values', () => {
  it('formats the Kampala wall clock for a datetime-local input', () => {
    expect(businessNowLocalInput(at('2026-11-21T21:05:00Z'))).toBe('2026-11-22T00:05');
    expect(businessNowLocalInput(at('2026-11-21T20:59:00Z'))).toBe('2026-11-21T23:59');
    expect(businessNowLocalInput(at('2026-06-15T12:30:00Z'))).toBe('2026-06-15T15:30');
  });

  it('gives the Kampala month', () => {
    expect(businessMonth(at('2026-11-30T21:30:00Z'))).toBe('2026-12');
    expect(businessMonth(at('2026-11-30T20:30:00Z'))).toBe('2026-11');
  });
});

describe('datetime-local values round-trip in the business zone', () => {
  it('reads an instant as Kampala wall clock', () => {
    expect(businessLocalInputOf('2026-11-21T22:00:00Z')).toBe('2026-11-22T01:00');
    expect(businessLocalInputOf(at('2026-11-21T22:00:00Z'))).toBe('2026-11-22T01:00');
  });

  it('turns a datetime-local value back into the same instant', () => {
    expect(businessLocalInputToIso('2026-11-22T01:00')).toBe('2026-11-21T22:00:00.000Z');
    expect(businessLocalInputToIso('2026-11-22T01:00:30')).toBe('2026-11-21T22:00:30.000Z');
  });

  it('opening and saving an unchanged activity does not move it', () => {
    for (const iso of ['2026-11-21T22:00:00Z', '2026-06-15T12:30:00Z', '2026-12-31T21:00:00Z', '2027-01-01T00:00:00Z']) {
      expect(businessLocalInputToIso(businessLocalInputOf(iso))).toBe(new Date(iso).toISOString());
    }
  });

  it('does not depend on the zone of the machine it runs on', () => {
    // The same value means the same instant, whatever TZ the browser or CI uses.
    const original = process.env.TZ;
    try {
      for (const tz of ['UTC', 'America/New_York', 'Pacific/Auckland', 'Africa/Kampala']) {
        process.env.TZ = tz;
        expect(businessLocalInputToIso('2026-07-01T09:15')).toBe('2026-07-01T06:15:00.000Z');
      }
    } finally {
      if (original === undefined) delete process.env.TZ; else process.env.TZ = original;
    }
  });

  it('rejects malformed values', () => {
    expect(() => businessLocalInputToIso('')).toThrow(RangeError);
    expect(() => businessLocalInputToIso('2026-11-22')).toThrow(RangeError);
    expect(() => businessLocalInputToIso('2026-13-40T99:99')).toThrow(RangeError);
  });

  it('keeps BUSINESS_UTC_OFFSET equal to what Intl says for BUSINESS_TIME_ZONE, all year', () => {
    for (const month of ['01', '04', '07', '10', '12']) {
      const instant = new Date(`2026-${month}-15T12:00:00Z`);
      const wall = new Intl.DateTimeFormat('en-GB', {
        timeZone: BUSINESS_TIME_ZONE, hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
      }).format(instant);
      const sign = BUSINESS_UTC_OFFSET[0] === '-' ? -1 : 1;
      const [oh, om] = BUSINESS_UTC_OFFSET.slice(1).split(':').map(Number);
      const expectedMinutes = (12 * 60 + sign * (oh * 60 + om)) % (24 * 60);
      const [wh, wm] = wall.split(':').map(Number);
      expect(wh * 60 + wm).toBe(expectedMinutes);
    }
  });
});

describe('calendar arithmetic', () => {
  it('adds days across months, years and a leap day', () => {
    expect(addDaysIso('2026-11-30', 1)).toBe('2026-12-01');
    expect(addDaysIso('2026-12-31', 1)).toBe('2027-01-01');
    expect(addDaysIso('2028-02-28', 1)).toBe('2028-02-29');
    expect(addDaysIso('2026-03-01', -1)).toBe('2026-02-28');
    expect(addDaysIso('2026-11-22', 0)).toBe('2026-11-22');
  });

  it('adds months and clamps to the end of a short month', () => {
    expect(addMonthsIso('2026-01-31', 1)).toBe('2026-02-28');
    expect(addMonthsIso('2028-01-31', 1)).toBe('2028-02-29');
    expect(addMonthsIso('2026-11-15', 3)).toBe('2027-02-15');
    expect(addMonthsIso('2026-01-15', -1)).toBe('2025-12-15');
    expect(addMonthsIso('2026-01-15', -13)).toBe('2024-12-15');
  });

  it('adds years, with 29 February falling back to 28 February', () => {
    expect(addYearsIso('2028-02-29', 1)).toBe('2029-02-28');
    expect(addYearsIso('2026-11-22', 1)).toBe('2027-11-22');
  });

  it('gives a policy a one-year term ending the day before the anniversary', () => {
    expect(addDaysIso(addYearsIso('2026-11-22', 1), -1)).toBe('2027-11-21');
  });

  it('refuses something that is not yyyy-mm-dd', () => {
    expect(() => addDaysIso('22/11/2026', 1)).toThrow(RangeError);
  });
});

describe('businessTodayDate', () => {
  it('reads as the Kampala calendar date through the local getters, in any browser zone', () => {
    const d = businessTodayDate(at('2026-11-21T22:00:00Z'));
    expect([d.getFullYear(), d.getMonth(), d.getDate()]).toEqual([2026, 10, 22]);
    const e = businessTodayDate(at('2026-11-21T20:00:00Z'));
    expect([e.getFullYear(), e.getMonth(), e.getDate()]).toEqual([2026, 10, 21]);
  });
});

describe('the edge-function copy', () => {
  it('is byte for byte the same file', () => {
    const web = readFileSync(resolve(__dirname, 'businessDate.ts'), 'utf8');
    const edge = readFileSync(resolve(__dirname, '../../../../supabase/functions/_shared/businessDate.ts'), 'utf8');
    expect(edge).toBe(web);
  });
});

// Guard: no screen, test or edge function may rebuild "today" from UTC or from the
// browser's own zone. Use businessToday() and the other helpers in businessDate.ts.
describe('no UTC or browser-zone "today" anywhere in the web app or the edge functions', () => {
  const roots = ['src', '../../supabase/functions'];
  const exempt = /(^|[\\/])businessDate(\.test)?\.ts$/;
  const banned: Array<[RegExp, string]> = [
    [/new Date\(\)\s*\.toISOString\(\)\s*\.(slice|substring|split)\(/, 'new Date().toISOString().slice(...) is the UTC date'],
    [/new Date\(\)\s*\.get(FullYear|Month|Date)\(/, 'new Date().getFullYear()/getMonth()/getDate() is the browser zone'],
    [/Date\.now\(\)[^;\n]*\.toISOString\(\)\s*\.(slice|substring|split)\(/, 'Date.now() - n days ... toISOString().slice(...) is the UTC date; use addDaysIso(businessToday(), -n)'],
    [/\.toISOString\(\)\s*\.slice\(0,\s*(7|16)\)/, 'toISOString().slice(0, 7|16) is the UTC month or datetime; use businessMonth(), businessNowLocalInput() or businessLocalInputOf()'],
    [/\blocalIsoDate\b|\bpolicyCashToday\b/, 'use businessToday() from lib/businessDate'],
  ];
  const walk = (dir: string): string[] =>
    readdirSync(dir).flatMap((n) => {
      const p = join(dir, n);
      if (statSync(p).isDirectory()) return n === 'node_modules' ? [] : walk(p);
      return /\.(ts|tsx)$/.test(n) && !exempt.test(p) ? [p] : [];
    });

  it('finds none', () => {
    const hits: string[] = [];
    for (const root of roots) {
      for (const file of walk(resolve(process.cwd(), root))) {
        const lines = readFileSync(file, 'utf8').split('\n');
        lines.forEach((line, i) => {
          for (const [re, why] of banned) if (re.test(line)) hits.push(`${file.replace(process.cwd(), '.')}:${i + 1}  ${why}`);
        });
      }
    }
    expect(hits).toEqual([]);
  });
});

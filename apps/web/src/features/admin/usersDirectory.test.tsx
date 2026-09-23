import { describe, expect, it } from 'vitest';
import {
  daysSince,
  lastSeenLabel,
  parseModules,
  summariseAccess,
  teamWarnings,
  usersToCsv,
  type DirectoryUser,
  type PlatformAdminRow,
} from './usersDirectory';

const NOW = Date.parse('2026-09-23T12:00:00Z');
const daysAgo = (n: number) => new Date(NOW - n * 86_400_000).toISOString();

function user(over: Partial<DirectoryUser> = {}): DirectoryUser {
  return {
    user_id: 'u1',
    name: 'Jane Doe',
    email: 'jane@acme.test',
    role_title: null,
    tenant_id: 't1',
    tenant_name: 'Acme',
    tenant_status: 'active',
    is_platform_admin: false,
    is_company_admin: false,
    modules: [],
    finance_role: null,
    mfa_enrolled: false,
    last_sign_in_at: null,
    created_at: daysAgo(100),
    total_count: 1,
    ...over,
  };
}

function admin(over: Partial<PlatformAdminRow> = {}): PlatformAdminRow {
  return {
    user_id: 'a1',
    name: 'Op One',
    email: 'op1@vendor.test',
    tenant_id: 't0',
    tenant_name: 'Platform (internal)',
    mfa_enrolled: true,
    last_sign_in_at: daysAgo(1),
    created_at: daysAgo(200),
    granted_at: null,
    granted_by_email: null,
    is_self: false,
    ...over,
  };
}

describe('parseModules', () => {
  it('reads the jsonb shape the RPC returns and sorts by module', () => {
    expect(parseModules([{ module: 'procurement', role: 'admin' }, { module: 'hr', role: 'member' }])).toEqual([
      { module: 'hr', role: 'member' },
      { module: 'procurement', role: 'admin' },
    ]);
  });
  it('tolerates garbage', () => {
    expect(parseModules(null)).toEqual([]);
    expect(parseModules('nope')).toEqual([]);
    expect(parseModules([1, 'x', { module: 'hr' }, { module: 'hr', role: 'admin' }])).toEqual([{ module: 'hr', role: 'admin' }]);
  });
});

describe('summariseAccess', () => {
  it('lists admin flags, module roles and finance in one line', () => {
    expect(
      summariseAccess(
        user({
          is_company_admin: true,
          modules: [{ module: 'hr', role: 'admin' }, { module: 'bd', role: 'member' }],
          finance_role: 'cost_control',
        }),
      ),
    ).toBe('Company admin · Business Dev member, HR admin · Cost control');
  });
  it('says so when nothing is granted', () => {
    expect(summariseAccess(user())).toBe('No access granted');
  });
});

describe('daysSince / lastSeenLabel', () => {
  it('handles never, today, yesterday and N days', () => {
    expect(daysSince(null, NOW)).toBeNull();
    expect(lastSeenLabel(null, NOW)).toBe('never');
    expect(lastSeenLabel(daysAgo(0), NOW)).toBe('today');
    expect(lastSeenLabel(daysAgo(1), NOW)).toBe('yesterday');
    expect(lastSeenLabel(daysAgo(45), NOW)).toBe('45 days ago');
    expect(lastSeenLabel('not a date', NOW)).toBe('never');
  });
});

describe('usersToCsv', () => {
  it('flattens modules and escapes commas', () => {
    const csv = usersToCsv([
      user({ name: 'Doe, Jane', modules: [{ module: 'hr', role: 'admin' }, { module: 'it', role: 'member' }], finance_role: 'finance' }),
    ]);
    const [header, line] = csv.split('\n');
    expect(header.startsWith('name,email,company,')).toBe(true);
    expect(line.startsWith('"Doe, Jane",jane@acme.test,Acme,active,,false,false,hr:admin it:member,finance,false,')).toBe(true);
  });
});

describe('teamWarnings', () => {
  it('flags a single admin, missing MFA and stale operators', () => {
    const only = teamWarnings([admin({ mfa_enrolled: false })], NOW);
    expect(only.some((w) => /Only one platform admin/.test(w))).toBe(true);
    expect(only.some((w) => /no authenticator enrolled: op1@vendor.test/.test(w))).toBe(true);
    // stale warning is suppressed when there is only one admin (nothing to remove)
    expect(only.some((w) => /60\+ days/.test(w))).toBe(false);

    const two = teamWarnings(
      [admin(), admin({ user_id: 'a2', email: 'op2@vendor.test', last_sign_in_at: daysAgo(90) })],
      NOW,
    );
    expect(two).toHaveLength(1);
    expect(two[0]).toMatch(/op2@vendor.test has not signed in for 60\+ days/);
  });
  it('is quiet when the team is healthy', () => {
    expect(teamWarnings([admin(), admin({ user_id: 'a2', email: 'op2@vendor.test' })], NOW)).toEqual([]);
  });
});

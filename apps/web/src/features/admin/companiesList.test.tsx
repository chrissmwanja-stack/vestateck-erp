import { describe, expect, it } from 'vitest';
import { applyCompanyFilters, companiesToCsv, EMPTY_FILTERS, filtersFromSearch, filtersToSearch, sortCompanies } from './companiesList';

// The Companies list's search / filter / sort / export are pure functions
// over the get_companies_overview() rows (companiesList.ts); pin their
// semantics here rather than through the (heavy) full-screen render.

const NOW = new Date('2026-09-22T12:00:00Z').getTime();
const DAY = 86_400_000;
const iso = (daysFromNow: number) => new Date(NOW + daysFromNow * DAY).toISOString();

const rows = [
  {
    id: 'a', name: 'Acme Ltd', status: 'active' as const, created_at: iso(-200),
    member_count: 8, module_count: 3, request_count_30d: 40, pending_request_count: 2,
    plan: 'standard', subscription_status: 'active', seat_limit: 10, trial_ends_at: null,
    read_only: false, contact_email: 'jane@acme.example', last_activity_at: iso(-1),
    onboarding_stage: 'live', onboarding_next_step: null, onboarding_stalled: false,
  },
  {
    id: 'b', name: 'Beta Builders', status: 'active' as const, created_at: iso(-20),
    member_count: 3, module_count: 5, request_count_30d: 0, pending_request_count: 0,
    plan: 'trial', subscription_status: 'trialing', seat_limit: 3, trial_ends_at: iso(5),
    read_only: false, contact_email: 'ops@beta.example', last_activity_at: iso(-45),
    onboarding_stage: 'first_activity', onboarding_next_step: 'No activity in the last 30 days - check in', onboarding_stalled: false,
  },
  {
    id: 'c', name: 'Gamma Group', status: 'suspended' as const, created_at: iso(-90),
    member_count: 12, module_count: 2, request_count_30d: 3, pending_request_count: 1,
    plan: 'enterprise', subscription_status: 'past_due', seat_limit: null, trial_ends_at: null,
    read_only: true, contact_email: null, last_activity_at: null,
  },
  {
    id: 'd', name: 'Delta Pending', status: 'pending' as const, created_at: iso(-2),
    member_count: 0, module_count: 0, request_count_30d: 0, pending_request_count: 0,
    plan: 'trial', subscription_status: 'trialing', seat_limit: null, trial_ends_at: iso(28),
    read_only: false, contact_email: 'new@delta.example', last_activity_at: null,
    onboarding_stage: 'admin_invited', onboarding_next_step: 'Waiting for the admin to accept', onboarding_stalled: true,
  },
];

const names = (r: { name: string }[]) => r.map((x) => x.name);

describe('applyCompanyFilters', () => {
  it('passes everything through with empty filters', () => {
    expect(applyCompanyFilters(rows, EMPTY_FILTERS, NOW)).toHaveLength(4);
  });

  it('searches name and contact email, case-insensitively', () => {
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, q: 'acme' }, NOW))).toEqual(['Acme Ltd']);
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, q: 'OPS@BETA' }, NOW))).toEqual(['Beta Builders']);
  });

  it('filters by status, plan and subscription', () => {
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, status: 'suspended' }, NOW))).toEqual(['Gamma Group']);
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, plan: 'trial' }, NOW))).toEqual(['Beta Builders', 'Delta Pending']);
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, subscription: 'past_due' }, NOW))).toEqual(['Gamma Group']);
  });

  it('"trial ending" means trialing with an end date within 14 days', () => {
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, flag: 'trial_ending' }, NOW))).toEqual(['Beta Builders']);
  });

  it('"quiet" means no activity in 30 days (or never), excluding pending companies', () => {
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, flag: 'quiet' }, NOW))).toEqual(['Beta Builders', 'Gamma Group']);
  });

  it('"read only" and "seats full" flags', () => {
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, flag: 'read_only' }, NOW))).toEqual(['Gamma Group']);
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, flag: 'seats_full' }, NOW))).toEqual(['Beta Builders']);
  });

  it('"stalled" flag and onboarding stage filter (rows without stage data never match a stage)', () => {
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, flag: 'stalled' }))).toEqual(['Delta Pending']);
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, stage: 'live' }))).toEqual(['Acme Ltd']);
    expect(names(applyCompanyFilters(rows, { ...EMPTY_FILTERS, stage: 'created' }))).toEqual([]);
  });

  it('combines filters with AND', () => {
    expect(applyCompanyFilters(rows, { ...EMPTY_FILTERS, plan: 'trial', status: 'pending' }, NOW)).toHaveLength(1);
    expect(applyCompanyFilters(rows, { ...EMPTY_FILTERS, plan: 'trial', flag: 'read_only' }, NOW)).toHaveLength(0);
  });
});

describe('filtersFromSearch / filtersToSearch', () => {
  it('round-trips known values and drops unknown ones', () => {
    const f = filtersFromSearch('?flag=stalled&stage=admin_invited&status=pending&q=delta&plan=trial');
    expect(f).toEqual({ q: 'delta', status: 'pending', plan: 'trial', subscription: '', flag: 'stalled', stage: 'admin_invited' });
    expect(filtersToSearch(f).toString()).toBe('q=delta&status=pending&plan=trial&flag=stalled&stage=admin_invited');
    expect(filtersFromSearch('?flag=bogus&stage=nope&status=deleted')).toEqual(EMPTY_FILTERS);
    expect(filtersToSearch(EMPTY_FILTERS).toString()).toBe('');
  });
});

describe('sortCompanies', () => {
  it('sorts by onboarding stage in funnel order, unknown last when descending', () => {
    expect(names(sortCompanies(rows, 'onboarding_stage', 'desc'))).toEqual(['Acme Ltd', 'Beta Builders', 'Delta Pending', 'Gamma Group']);
  });

  it('sorts by name asc/desc', () => {
    expect(names(sortCompanies(rows, 'name', 'asc'))).toEqual(['Acme Ltd', 'Beta Builders', 'Delta Pending', 'Gamma Group']);
    expect(names(sortCompanies(rows, 'name', 'desc'))[0]).toBe('Gamma Group');
  });

  it('sorts dates with nulls first ascending (never active = oldest)', () => {
    const asc = names(sortCompanies(rows, 'last_activity_at', 'asc'));
    expect(asc.slice(-1)).toEqual(['Acme Ltd']);
    expect(asc.slice(0, 2).sort()).toEqual(['Delta Pending', 'Gamma Group']);
  });

  it('sorts numeric columns', () => {
    expect(names(sortCompanies(rows, 'member_count', 'desc'))).toEqual(['Gamma Group', 'Acme Ltd', 'Beta Builders', 'Delta Pending']);
  });

  it('does not mutate its input', () => {
    const copy = [...rows];
    sortCompanies(rows, 'name', 'desc');
    expect(rows).toEqual(copy);
  });
});

describe('companiesToCsv', () => {
  it('emits a header and one line per row, escaping as needed', () => {
    const csv = companiesToCsv([{ ...rows[0], name: 'Acme, "The" Ltd' }]);
    const [header, line] = csv.split('\n');
    expect(header.split(',')[0]).toBe('name');
    expect(header.split(',')).toContain('tenant_id');
    expect(line.startsWith('"Acme, ""The"" Ltd",active,standard,active,no,jane@acme.example,8,10,3,40,2,')).toBe(true);
    expect(line.endsWith(',a')).toBe(true);
  });

  it('renders nulls as empty fields', () => {
    const line = companiesToCsv([rows[2]]).split('\n')[1];
    expect(line).toContain(',yes,,12,,2,3,1,,,');
  });
});

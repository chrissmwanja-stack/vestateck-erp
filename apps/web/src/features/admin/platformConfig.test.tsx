import { describe, expect, it } from 'vitest';
import {
  announcementDraftFrom,
  choiceOf,
  cronLevel,
  describeStage,
  draftFromTemplate,
  emptyStage,
  enabledFromChoice,
  formatBytes,
  fromLocalInput,
  hoursAgo,
  itemsFromDraft,
  jobLevel,
  normaliseHealth,
  overallLevel,
  overridesOf,
  reindexStages,
  slugifyTemplateKey,
  sortAnnouncements,
  toLocalInput,
  validateAnnouncement,
  validateTemplateDraft,
  type AnnouncementRow,
  type HealthJob,
  type PlatformHealth,
  type TemplateDraft,
  type TemplateRow,
} from './platformConfig';

// Pure helpers behind the item-7 screens. The round trip server row ->
// draft -> p_items matters most: it is how the operator's edits reach
// save_industry_template(), and a stage whose next_low points at the
// wrong position would silently break approvals for every company
// created from the template afterwards.

const GENERAL_ROW: TemplateRow = {
  key: 'general',
  name: 'General',
  description: 'desc',
  is_active: true,
  is_default: true,
  sort_order: 10,
  updated_at: '2026-09-23T00:00:00Z',
  department_count: 2,
  module_count: 1,
  stage_count: 3,
  tenants_using: 4,
  items: [
    { id: 'a', kind: 'department', sort_order: 2, name: 'Finance', payload: {} },
    { id: 'b', kind: 'department', sort_order: 1, name: 'Cost Control', payload: {} },
    { id: 'c', kind: 'module', sort_order: 1, name: 'hr', payload: {} },
    { id: 'd', kind: 'workflow_stage', sort_order: 1, name: 'Engineer', payload: { approver_role: 'Eng', next_low: 2 } },
    {
      id: 'e',
      kind: 'workflow_stage',
      sort_order: 2,
      name: 'Chief',
      payload: { approver_role: 'Chief', threshold_amount: 5000000, next_low: 3, next_high: 3, is_finance_terminal_stage: false },
    },
    { id: 'f', kind: 'workflow_stage', sort_order: 3, name: 'Finance', payload: { approver_role: 'FO', is_finance_terminal_stage: true } },
  ],
};

describe('industry template drafts', () => {
  it('orders items by sort_order and maps stage payloads into the draft', () => {
    const d = draftFromTemplate(GENERAL_ROW);
    expect(d.departments).toEqual(['Cost Control', 'Finance']);
    expect(d.modules).toEqual(['hr']);
    expect(d.stages.map((s) => s.name)).toEqual(['Engineer', 'Chief', 'Finance']);
    expect(d.stages[1]).toMatchObject({ threshold_amount: '5000000', next_low: 3, next_high: 3, approver_role: 'Chief' });
    expect(d.stages[2].is_finance_terminal_stage).toBe(true);
  });

  it('round-trips to p_items with 1-based sort orders and only the set flags', () => {
    const items = itemsFromDraft(draftFromTemplate(GENERAL_ROW));
    expect(items.filter((i) => i.kind === 'department').map((i) => [i.sort_order, i.name])).toEqual([
      [1, 'Cost Control'],
      [2, 'Finance'],
    ]);
    const chief = items.find((i) => i.name === 'Chief')!;
    expect(chief.payload).toEqual({ approver_role: 'Chief', threshold_amount: 5000000, next_low: 3, next_high: 3 });
    const fin = items.find((i) => i.name === 'Finance' && i.kind === 'workflow_stage')!;
    expect(fin.payload).toEqual({ approver_role: 'FO', is_finance_terminal_stage: true });
  });

  it('validates the same rules the server enforces, with readable messages', () => {
    const ok = draftFromTemplate(GENERAL_ROW);
    expect(validateTemplateDraft(ok)).toEqual([]);

    const bad: TemplateDraft = {
      key: 'Bad Key',
      name: '',
      description: '',
      is_active: true,
      departments: ['A', 'a'],
      modules: [],
      stages: [{ ...emptyStage(1), name: 'S', approver_role: '', threshold_amount: '100', next_low: 5, next_high: null }],
    };
    const errs = validateTemplateDraft(bad);
    expect(errs.some((e) => /Key must be/.test(e))).toBe(true);
    expect(errs.some((e) => /name/.test(e))).toBe(true);
    expect(errs.some((e) => /unique/.test(e))).toBe(true);
    expect(errs.some((e) => /approver role/.test(e))).toBe(true);
    expect(errs.some((e) => /no "above threshold"/.test(e))).toBe(true);
    expect(errs.some((e) => /does not exist/.test(e))).toBe(true);
    expect(validateTemplateDraft({ ...bad, stages: [] }).some((e) => /at least one approval stage/.test(e))).toBe(true);
  });

  it('re-points routing when a stage is removed or moved', () => {
    const d = draftFromTemplate(GENERAL_ROW);
    // remove "Chief" (index 1): Engineer's next_low pointed at 2 (Chief) -> cleared; Finance becomes 2
    const removed = reindexStages(d.stages.filter((_, i) => i !== 1), 1);
    expect(removed.map((s) => s.sort_order)).toEqual([1, 2]);
    expect(removed[0].next_low).toBeNull();

    // swap Chief and Finance: Engineer -> Chief must now be 3
    const arr = [...d.stages];
    [arr[1], arr[2]] = [arr[2], arr[1]];
    const moved = reindexStages(arr);
    expect(moved.map((s) => s.name)).toEqual(['Engineer', 'Finance', 'Chief']);
    expect(moved[0].next_low).toBe(3);
    expect(moved[2].next_low).toBe(2); // Chief -> Finance, now at 2
  });

  it('describes a stage in one line', () => {
    const d = draftFromTemplate(GENERAL_ROW);
    expect(describeStage(d.stages[1], d.stages)).toBe('Chief: ≤ 5,000,000 → Finance, above → Finance');
    expect(describeStage(d.stages[2], d.stages)).toBe('Finance → end');
  });

  it('slugifies a name into a valid key', () => {
    expect(slugifyTemplateKey('Oil & Gas (Upstream)')).toBe('oil_gas_upstream');
    expect(slugifyTemplateKey('123 Retail')).toBe('retail');
    expect(slugifyTemplateKey('X')).toBe('');
  });
});

describe('announcements', () => {
  const row: AnnouncementRow = {
    id: '1',
    title: 'T',
    body: 'B',
    severity: 'warning',
    tenant_id: null,
    tenant_name: null,
    starts_at: '2026-09-23T10:00:00Z',
    ends_at: null,
    dismissible: true,
    link_url: null,
    link_label: null,
    is_active: true,
    state: 'live',
    dismissals: 0,
    created_at: '2026-09-23T09:00:00Z',
    created_by_email: 'ops@x',
  };

  it('converts between ISO and datetime-local values without drifting', () => {
    const local = toLocalInput(row.starts_at);
    expect(local).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/);
    expect(new Date(fromLocalInput(local)!).getTime()).toBe(new Date(row.starts_at).getTime());
    expect(toLocalInput(null)).toBe('');
    expect(fromLocalInput('')).toBeNull();
  });

  it('builds a draft and validates windows and links', () => {
    const d = announcementDraftFrom(row);
    expect(d.severity).toBe('warning');
    expect(validateAnnouncement(d)).toEqual([]);
    expect(validateAnnouncement({ ...d, title: ' ' })).toContain('Title is required.');
    expect(validateAnnouncement({ ...d, ends_at: toLocalInput('2026-09-23T09:00:00Z') })).toContain('End must be after start.');
    expect(validateAnnouncement({ ...d, link_url: 'ftp://x' })).toContain('Link must start with https:// or /.');
    expect(validateAnnouncement({ ...d, link_url: '/help' })).toContain('Give the link a label.');
    expect(validateAnnouncement({ ...d, link_url: '/help', link_label: 'Help' })).toEqual([]);
  });

  it('sorts live first, then scheduled, ended, disabled', () => {
    const rows = [
      { ...row, id: 'd', state: 'disabled' },
      { ...row, id: 'e', state: 'ended' },
      { ...row, id: 's', state: 'scheduled' },
      { ...row, id: 'l2', state: 'live', starts_at: '2026-09-22T00:00:00Z' },
      { ...row, id: 'l1', state: 'live' },
    ];
    expect(sortAnnouncements(rows).map((r) => r.id)).toEqual(['l1', 'l2', 's', 'e', 'd']);
  });
});

describe('feature flags', () => {
  it('maps override tri-state both ways', () => {
    expect(choiceOf({ override: null })).toBe('default');
    expect(choiceOf({ override: true })).toBe('on');
    expect(choiceOf({ override: false })).toBe('off');
    expect(enabledFromChoice('default')).toBeNull();
    expect(enabledFromChoice('on')).toBe(true);
    expect(enabledFromChoice('off')).toBe(false);
  });

  it('parses the overrides jsonb defensively', () => {
    expect(overridesOf({ key: 'k', description: null, default_enabled: false, updated_at: '', tenants_on: 0, tenants_off: 0, overrides: null })).toEqual([]);
    const o = overridesOf({
      key: 'k',
      description: null,
      default_enabled: false,
      updated_at: '',
      tenants_on: 1,
      tenants_off: 0,
      overrides: [{ tenant_id: 't1', tenant_name: 'Acme', enabled: true, note: null, updated_at: 'x' }],
    });
    expect(o).toEqual([{ tenant_id: 't1', tenant_name: 'Acme', enabled: true, note: null, updated_at: 'x' }]);
  });
});

describe('health', () => {
  const now = new Date('2026-09-23T12:00:00Z');
  const job = (over: Partial<HealthJob>): HealthJob => ({
    job: 'operator_digest',
    last_run_at: '2026-09-23T04:00:00Z',
    last_status: 'ok',
    last_affected: 1,
    last_detail: null,
    runs_7d: 7,
    errors_7d: 0,
    tenants_7d: 0,
    ...over,
  });

  it('judges jobs by errors first, then expected cadence (sweeps have none)', () => {
    expect(jobLevel(job({}), now)).toBe('ok');
    expect(jobLevel(job({ last_run_at: '2026-09-20T04:00:00Z' }), now)).toBe('warn'); // digest > 36h
    expect(jobLevel(job({ errors_7d: 1 }), now)).toBe('error');
    expect(jobLevel(job({ last_run_at: null }), now)).toBe('unknown');
    expect(jobLevel(job({ job: 'machine_maintenance_overdue_sweep', last_run_at: '2026-08-01T00:00:00Z' }), now)).toBe('ok');
  });

  it('judges cron by active + last status', () => {
    const base = { jobname: 'j', schedule: '0 4 * * *', active: true, last_status: 'succeeded', last_start: null, last_end: null, last_message: null };
    expect(cronLevel(base)).toBe('ok');
    expect(cronLevel({ ...base, last_status: 'failed' })).toBe('error');
    expect(cronLevel({ ...base, active: false })).toBe('warn');
    expect(cronLevel({ ...base, last_status: null })).toBe('unknown');
  });

  it('normalises a partial jsonb and rolls up the worst level', () => {
    const h = normaliseHealth({ database: { size_bytes: 1024 * 1024 * 5 }, jobs: [job({})], cron: { installed: true, jobs: [] } } as unknown as Parameters<typeof normaliseHealth>[0]);
    expect(h.database.size_bytes).toBe(5 * 1024 * 1024);
    expect(h.stuck_approvals).toEqual([]);
    expect(h.storage.available).toBe(false);
    expect(overallLevel(h, now)).toBe('ok');

    const worse: PlatformHealth = { ...h, stuck_approvals: [{ tenant_id: 't', tenant_name: 'A', count: 2, oldest_days: 12 }] };
    expect(overallLevel(worse, now)).toBe('warn');
    expect(overallLevel({ ...worse, digest: { ...h.digest, failed_7d: 1 } }, now)).toBe('error');
    expect(overallLevel({ ...h, cron: { installed: false, jobs: [] } }, now)).toBe('warn');
  });

  it('formats bytes and ages', () => {
    expect(formatBytes(512)).toBe('512 B');
    expect(formatBytes(5 * 1024 * 1024)).toBe('5.0 MB');
    expect(formatBytes(3.5 * 1024 ** 3)).toBe('3.5 GB');
    expect(hoursAgo(null, now)).toBe('never');
    expect(hoursAgo('2026-09-23T11:30:00Z', now)).toBe('30 min ago');
    expect(hoursAgo('2026-09-23T04:00:00Z', now)).toBe('8 h ago');
    expect(hoursAgo('2026-09-10T04:00:00Z', now)).toBe('13 d ago');
  });
});
import { describe, expect, it } from 'vitest';
import {
  classifyCompanyModules,
  funnelSummary,
  normaliseFunnel,
  sortStalled,
  trendLabel,
  trendOf,
  underusedModules,
  STAGE_ORDER,
  type FunnelRow,
  type StalledRow,
} from './platformHealth';

describe('normaliseFunnel / funnelSummary', () => {
  it('fills missing stages with zero in canonical order', () => {
    const f = normaliseFunnel([{ stage: 6, stage_key: 'live', count: 3 }, { stage: 1, stage_key: 'admin_invited', count: 2 }]);
    expect(f.map((r) => r.stage_key)).toEqual(STAGE_ORDER);
    expect(f.map((r) => r.count)).toEqual([0, 2, 0, 0, 0, 0, 3]);
  });
  it('tolerates null', () => {
    expect(normaliseFunnel(null).every((r) => r.count === 0)).toBe(true);
  });
  it('sums setup vs not-live vs live', () => {
    const rows: FunnelRow[] = [
      { stage: 0, stage_key: 'created', count: 1 },
      { stage: 3, stage_key: 'modules_enabled', count: 2 },
      { stage: 5, stage_key: 'first_activity', count: 4 },
      { stage: 6, stage_key: 'live', count: 8 },
    ];
    expect(funnelSummary(rows)).toEqual({ inSetup: 3, notLive: 4, live: 8, total: 15 });
  });
});

describe('trendOf / trendLabel', () => {
  it('classifies the obvious cases', () => {
    expect(trendOf(0, 0)).toBe('none');
    expect(trendOf(3, 0)).toBe('new');
    expect(trendOf(0, 3)).toBe('down');
    expect(trendOf(2, 3)).toBe('flat'); // too small to call
    expect(trendOf(11, 10)).toBe('flat');
    expect(trendOf(15, 10)).toBe('up');
    expect(trendOf(6, 10)).toBe('down');
  });
  it('labels with a percentage where it means something', () => {
    expect(trendLabel(15, 10)).toBe('↑ 50% vs previous 30d');
    expect(trendLabel(5, 10)).toBe('↓ 50% vs previous 30d');
    expect(trendLabel(4, 0)).toBe('new this month');
    expect(trendLabel(0, 0)).toBe('no activity');
    expect(trendLabel(11, 10)).toBe('steady');
  });
});

describe('underusedModules', () => {
  it('flags modules enabled by many but touched by fewer than half', () => {
    const rows = [
      { module: 'hr', tenants_enabled: 10, tenants_active_30d: 3, events_30d: 9, events_prev_30d: 4 },
      { module: 'bd', tenants_enabled: 4, tenants_active_30d: 2, events_30d: 9, events_prev_30d: 4 },
      { module: 'pmo', tenants_enabled: 0, tenants_active_30d: 0, events_30d: 0, events_prev_30d: 0 },
    ];
    expect(underusedModules(rows).map((r) => r.module)).toEqual(['hr']);
  });
});

describe('sortStalled', () => {
  it('orders longest-stuck first, then earliest stage', () => {
    const mk = (name: string, days: number, stage: number): StalledRow => ({
      id: name, name, status: 'pending', stage, stage_key: 'created', next_step: null, days_in_stage: days, created_at: '', contact_email: null,
    });
    const out = sortStalled([mk('b', 10, 3), mk('a', 10, 1), mk('c', 30, 4)]);
    expect(out.map((r) => r.name)).toEqual(['c', 'a', 'b']);
  });
});

describe('classifyCompanyModules', () => {
  it('splits enabled/used, enabled/unused, used-but-off, off', () => {
    const rows = [
      { module: 'hr', enabled: true, events_30d: 3, events_prev_30d: 1, first_event_at: 'x', last_event_at: 'y' },
      { module: 'it', enabled: true, events_30d: 0, events_prev_30d: 0, first_event_at: null, last_event_at: null },
      { module: 'pmo', enabled: false, events_30d: 1, events_prev_30d: 0, first_event_at: 'x', last_event_at: 'y' },
      { module: 'legal', enabled: false, events_30d: 0, events_prev_30d: 0, first_event_at: null, last_event_at: null },
    ];
    const c = classifyCompanyModules(rows);
    expect(c.used.map((r) => r.module)).toEqual(['hr']);
    expect(c.enabledUnused.map((r) => r.module)).toEqual(['it']);
    expect(c.usedButOff.map((r) => r.module)).toEqual(['pmo']);
    expect(c.off.map((r) => r.module)).toEqual(['legal']);
  });
});

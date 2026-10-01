import { describe, expect, it } from 'vitest';
import { readinessChecks, readinessHeadline, readinessPercent, type ReadinessInput } from './companyReadiness';

const FULL: ReadinessInput = {
  departments: 4,
  positions: 12,
  members: 9,
  teamInvites: 2,
  modulesEnabled: 6,
  workflowStages: 7,
  approvalAssignments: 5,
};

const EMPTY: ReadinessInput = {
  departments: 0,
  positions: 0,
  members: 1,
  teamInvites: 0,
  modulesEnabled: 0,
  workflowStages: 0,
  approvalAssignments: 0,
};

describe('readinessChecks', () => {
  it('marks every check done for a fully configured company', () => {
    const checks = readinessChecks(FULL);
    expect(checks).toHaveLength(5);
    expect(checks.every((c) => c.done === true)).toBe(true);
  });

  it('flags the gaps on a fresh company', () => {
    const byKey = Object.fromEntries(readinessChecks(EMPTY).map((c) => [c.key, c]));
    expect(byKey.departments.done).toBe(false);
    expect(byKey.positions.done).toBe(false);
    expect(byKey.team.done).toBe(false); // admin alone doesn't count
    expect(byKey.modules.done).toBe(false);
    expect(byKey.workflow.done).toBe(false);
  });

  it('counts pending invites toward "team invited"', () => {
    const checks = readinessChecks({ ...EMPTY, teamInvites: 3 });
    expect(checks.find((c) => c.key === 'team')?.done).toBe(true);
  });

  it('treats stages without approver assignments as not done', () => {
    const checks = readinessChecks({ ...EMPTY, workflowStages: 7, approvalAssignments: 0 });
    const workflow = checks.find((c) => c.key === 'workflow');
    expect(workflow?.done).toBe(false);
    expect(workflow?.detail).toMatch(/no approvers assigned/i);
  });

  it('reports unknown (null) when a count could not be read', () => {
    const checks = readinessChecks({ ...FULL, departments: null });
    expect(checks.find((c) => c.key === 'departments')?.done).toBeNull();
  });

  it('links every actionable check into the company-admin namespace', () => {
    for (const c of readinessChecks(FULL)) {
      if (!c.linkTo) continue;
      expect(c.linkTo.startsWith('/company-admin/') || c.linkTo.startsWith('/hr/')).toBe(true);
    }
  });
});

describe('readinessPercent / readinessHeadline', () => {
  it('scores done checks out of known checks only', () => {
    const checks = readinessChecks({ ...FULL, departments: null });
    expect(readinessPercent(checks)).toBe(100); // 4/4 known, null excluded
  });

  it('returns null when nothing is known', () => {
    const checks = readinessChecks({
      departments: null,
      positions: null,
      members: null,
      teamInvites: null,
      modulesEnabled: null,
      workflowStages: null,
      approvalAssignments: null,
    });
    expect(readinessPercent(checks)).toBeNull();
    expect(readinessHeadline(null)).toMatch(/checking/i);
  });

  it('computes a partial score', () => {
    const checks = readinessChecks(EMPTY);
    expect(readinessPercent(checks)).toBe(0);
    expect(readinessHeadline(0)).toMatch(/not configured/i);
    expect(readinessHeadline(100)).toMatch(/fully configured/i);
    expect(readinessHeadline(75)).toMatch(/nearly there/i);
  });
});

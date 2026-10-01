// Readiness model behind the Company Admin dashboard: "is this company
// properly configured to operate?" Pure and unit-tested; the dashboard
// component only fetches counts and renders the result.
//
// Counts arrive nullable: any query a given role cannot read degrades to
// null, which reads as "unknown", never as "done".

export interface ReadinessInput {
  departments: number | null;
  positions: number | null;
  members: number | null;
  teamInvites: number | null;
  modulesEnabled: number | null;
  workflowStages: number | null;
  approvalAssignments: number | null;
}

export interface ReadinessCheck {
  key: 'departments' | 'positions' | 'team' | 'modules' | 'workflow';
  label: string;
  detail: string;
  // null = could not be determined (query failed / no access).
  done: boolean | null;
  linkTo: string;
  linkLabel: string;
}

export function readinessChecks(i: ReadinessInput): ReadinessCheck[] {
  const teamCount = (i.members ?? 0) + (i.teamInvites ?? 0);
  return [
    {
      key: 'departments',
      label: 'Departments',
      detail:
        i.departments == null
          ? 'Could not read departments.'
          : i.departments > 0
            ? `${i.departments} department${i.departments === 1 ? '' : 's'} configured.`
            : 'The backbone of your org chart and reporting lines.',
      done: i.departments == null ? null : i.departments > 0,
      linkTo: '/company-admin/organization/departments',
      linkLabel: 'Manage departments',
    },
    {
      key: 'positions',
      label: 'Job positions',
      detail:
        i.positions == null
          ? 'Could not read positions.'
          : i.positions > 0
            ? `${i.positions} position${i.positions === 1 ? '' : 's'} defined.`
            : 'Positions must exist before employees can be added.',
      done: i.positions == null ? null : i.positions > 0,
      linkTo: '/hr/admin/positions',
      linkLabel: 'Manage positions',
    },
    {
      key: 'team',
      label: 'Team invited',
      detail:
        i.members == null && i.teamInvites == null
          ? 'Could not read team data.'
          : teamCount > 1
            ? `${i.members ?? 0} member${(i.members ?? 0) === 1 ? '' : 's'}${i.teamInvites ? `, ${i.teamInvites} invite${i.teamInvites === 1 ? '' : 's'} out` : ''}.`
            : 'Bring in teammates and choose their modules and roles.',
      done: i.members == null && i.teamInvites == null ? null : teamCount > 1,
      linkTo: '/company-admin/users/invite',
      linkLabel: 'Invite teammates',
    },
    {
      key: 'modules',
      label: 'Modules enabled',
      detail:
        i.modulesEnabled == null
          ? 'Could not read module entitlements.'
          : i.modulesEnabled > 0
            ? `${i.modulesEnabled} module${i.modulesEnabled === 1 ? '' : 's'} switched on for this company.`
            : 'No modules are switched on yet — ask the platform team.',
      done: i.modulesEnabled == null ? null : i.modulesEnabled > 0,
      linkTo: '',
      linkLabel: '',
    },
    {
      key: 'workflow',
      label: 'Approval workflow',
      detail:
        i.workflowStages == null
          ? 'Could not read the workflow.'
          : i.workflowStages === 0
            ? 'No approval pipeline configured.'
            : i.approvalAssignments != null && i.approvalAssignments === 0
              ? `${i.workflowStages} stages, but no approvers assigned yet.`
              : `${i.workflowStages} stages${i.approvalAssignments ? `, ${i.approvalAssignments} approver assignment${i.approvalAssignments === 1 ? '' : 's'}` : ''}.`,
      done: i.workflowStages == null ? null : i.workflowStages > 0 && (i.approvalAssignments == null || i.approvalAssignments > 0),
      linkTo: '/company-admin/workflows/approvals',
      linkLabel: 'Review workflow',
    },
  ];
}

// Percent of known checks that are done; unknowns are excluded from the
// denominator so a failed query doesn't drag the score down.
export function readinessPercent(checks: ReadinessCheck[]): number | null {
  const known = checks.filter((c) => c.done != null);
  if (known.length === 0) return null;
  return Math.round((known.filter((c) => c.done).length / known.length) * 100);
}

export function readinessHeadline(percent: number | null): string {
  if (percent == null) return 'Checking your company setup…';
  if (percent === 100) return 'Fully configured — ready to operate.';
  if (percent >= 60) return 'Nearly there — a couple of steps left.';
  if (percent > 0) return 'Good start — finish the setup before real data flows.';
  return 'Not configured yet — walk through the steps below.';
}

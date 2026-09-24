export const appliesToLabel: Record<string, string> = {
  requests: 'Procurement requests',
  invoices: 'Invoices',
};

export const tenantStatusColor: Record<string, 'default' | 'success' | 'warning'> = {
  pending: 'warning',
  active: 'success',
  suspended: 'default',
};

export const PLAN_OPTIONS = [
  { value: 'trial', label: 'Trial' },
  { value: 'starter', label: 'Starter' },
  { value: 'standard', label: 'Standard' },
  { value: 'enterprise', label: 'Enterprise' },
  { value: 'internal', label: 'Internal (platform)' },
];

export const SUBSCRIPTION_OPTIONS = [
  { value: 'trialing', label: 'Trialing' },
  { value: 'active', label: 'Active (paid)' },
  { value: 'past_due', label: 'Past due' },
  { value: 'cancelled', label: 'Cancelled' },
];

export const subscriptionColor: Record<string, 'default' | 'success' | 'warning' | 'error' | 'info'> = {
  trialing: 'info',
  active: 'success',
  past_due: 'warning',
  cancelled: 'error',
};

export const ACTION_LABEL: Record<string, string> = {
  'tenant.suspend': 'Suspended',
  'tenant.activate': 'Reactivated',
  'tenant.read_only.on': 'Read-only enabled',
  'tenant.read_only.off': 'Read-only lifted',
  'tenant.profile.update': 'Profile edited',
  'tenant.modules.set': 'Modules changed',
  'impersonation.start': 'View-as started',
  'impersonation.end': 'View-as ended',
  'workflow.threshold.update': 'Threshold edited',
  'invitation.revoke': 'Invite revoked',
};
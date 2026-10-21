import type { ReactNode } from 'react';
import { Alert, Box, Chip, Typography } from '@mui/material';
import { localIsoDate } from './fx';
import { CLAIM_STATUS_LABEL, COMMISSION_STATUS_LABEL, POLICY_DISPLAY_STATUS_LABEL, policyDisplayStatus, type PolicyDisplayStatus } from './logic';
import type { ClaimStatus, CommissionStatus, PolicyStatus } from './types';

export function PageHeader({ title, subtitle, actions }: { title: string; subtitle?: string; actions?: ReactNode }) {
  return (
    <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 2, gap: 2, flexWrap: 'wrap' }}>
      <Box>
        <Typography variant="h5" fontWeight={700}>
          {title}
        </Typography>
        {subtitle && (
          <Typography variant="body2" color="text.secondary">
            {subtitle}
          </Typography>
        )}
      </Box>
      {actions}
    </Box>
  );
}

const POLICY_COLOR: Record<PolicyDisplayStatus, 'default' | 'primary' | 'success' | 'warning'> = {
  expired: 'warning',
  draft: 'default',
  active: 'success',
  renewed: 'primary',
  reversed: 'default',
  cancelled: 'default',
};

const CLAIM_COLOR: Record<ClaimStatus, 'default' | 'primary' | 'warning' | 'success' | 'error'> = {
  notified: 'primary',
  assessing: 'warning',
  approved: 'success',
  settled: 'success',
  repudiated: 'error',
  closed: 'default',
};

const COMMISSION_COLOR: Record<CommissionStatus, 'default' | 'primary' | 'success'> = {
  deferred: 'default',
  earned: 'success',
  transferred: 'primary',
};

/** Pass `expiryDate` so an active policy past its expiry shows as Expired. */
export function PolicyStatusChip({ status, expiryDate }: { status: PolicyStatus; expiryDate?: string | null }) {
  const shown: PolicyDisplayStatus = expiryDate ? policyDisplayStatus({ status, expiry_date: expiryDate }, localIsoDate()) : status;
  return <Chip size="small" label={POLICY_DISPLAY_STATUS_LABEL[shown]} color={POLICY_COLOR[shown]} variant={shown === 'draft' ? 'outlined' : 'filled'} />;
}

export function ClaimStatusChip({ status }: { status: ClaimStatus }) {
  return <Chip size="small" label={CLAIM_STATUS_LABEL[status]} color={CLAIM_COLOR[status]} variant={status === 'closed' ? 'outlined' : 'filled'} />;
}

export function CommissionStatusChip({ status }: { status: CommissionStatus }) {
  return <Chip size="small" label={COMMISSION_STATUS_LABEL[status]} color={COMMISSION_COLOR[status]} variant={status === 'deferred' ? 'outlined' : 'filled'} />;
}

export function ErrorBanner({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <Alert severity="error" sx={{ mb: 2 }}>
      {message}
    </Alert>
  );
}

export function EmptyRow({ colSpan, text }: { colSpan: number; text: string }) {
  return (
    <tr>
      <td colSpan={colSpan} style={{ textAlign: 'center', padding: '40px 0' }}>
        <Typography color="text.secondary">{text}</Typography>
      </td>
    </tr>
  );
}

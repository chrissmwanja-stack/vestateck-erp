import type { ReactNode } from 'react';
import { Alert, Box, Chip, Typography } from '@mui/material';
import { CLAIM_STATUS_LABEL, POLICY_STATUS_LABEL } from './logic';
import type { ClaimStatus, PolicyStatus } from './types';

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

const POLICY_COLOR: Record<PolicyStatus, 'default' | 'primary' | 'success'> = {
  draft: 'default',
  active: 'success',
  renewed: 'primary',
};

const CLAIM_COLOR: Record<ClaimStatus, 'default' | 'primary' | 'warning' | 'success' | 'error'> = {
  notified: 'primary',
  assessing: 'warning',
  approved: 'success',
  settled: 'success',
  repudiated: 'error',
  closed: 'default',
};

export function PolicyStatusChip({ status }: { status: PolicyStatus }) {
  return <Chip size="small" label={POLICY_STATUS_LABEL[status]} color={POLICY_COLOR[status]} variant={status === 'draft' ? 'outlined' : 'filled'} />;
}

export function ClaimStatusChip({ status }: { status: ClaimStatus }) {
  return <Chip size="small" label={CLAIM_STATUS_LABEL[status]} color={CLAIM_COLOR[status]} variant={status === 'closed' ? 'outlined' : 'filled'} />;
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

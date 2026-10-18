import type { InsClient } from './types';

export type KycStatus = InsClient['kyc_status'];

export const KYC_LABEL: Record<KycStatus, string> = { pending: 'Pending', verified: 'Verified', expired: 'Expired' };

/** What each KYC decision means, shown in the confirmation so a manager knows what they are signing off. */
export const KYC_MEANING: Record<KycStatus, string> = {
  pending: 'Documents are still to be collected or checked.',
  verified: 'Identity and tax documents have been checked and are on file.',
  expired: 'The checked documents are out of date and must be collected again.',
};

/** The statuses a client can move to from its current one. Any other status; a manager chooses. */
export function kycTargets(current: KycStatus): KycStatus[] {
  return (['verified', 'expired', 'pending'] as KycStatus[]).filter((s) => s !== current);
}

export const KYC_ACTION_LABEL: Record<KycStatus, string> = { verified: 'Mark verified', expired: 'Mark expired', pending: 'Reset to pending' };

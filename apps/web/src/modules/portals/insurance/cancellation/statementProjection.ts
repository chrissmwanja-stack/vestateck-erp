import type { InsurerShare } from '../financialConfiguration';
import type { Policy } from '../types';
interface PolicyWithCancellation extends Policy {
  ins_policy_insurer_shares?: InsurerShare[];
  ins_policy_cancellations?: {
    status: string;
    calculation: {
      insurers?: {
        insurer_id: string;
        return_premium: string;
        commission_clawback: string;
        total_insurer_credit: string;
      }[];
    };
  }[];
}
/** Reporting projection only; bound policy/header/share records remain original.
 * Cancelled rows present retained premium/payable/commission, not original gross
 * paired with a newly reduced commission that falsely implies a changed rate.
 */
export function projectInsurerStatementPolicy(
  p: PolicyWithCancellation,
  insurerId: string,
): Policy[] {
  const share = p.ins_policy_insurer_shares?.find(
    (s) => s.insurer_id === insurerId && s.premium_amount != null,
  );
  if (
    !share &&
    (p.insurer_id !== insurerId ||
      p.ins_policy_insurer_shares?.some((s) => s.premium_amount != null))
  )
    return [];
  const base: Policy = share
    ? {
        ...p,
        insurer_id: insurerId,
        gross_premium: Number(share.premium_amount),
        commission_rate_pct: share.commission_rate_pct,
        commission_amount: share.commission_amount ?? 0,
        net_premium_to_insurer: share.payable_amount ?? 0,
      }
    : p;
  const adjustment = p.ins_policy_cancellations
    ?.find((c) => c.status === 'posted')
    ?.calculation.insurers?.find((s) => s.insurer_id === insurerId);
  if (!adjustment) return [base];
  return [
    {
      ...base,
      gross_premium: Number(
        (base.gross_premium - Number(adjustment.return_premium)).toFixed(2),
      ),
      commission_amount: Number(
        (
          (base.commission_amount ?? 0) - Number(adjustment.commission_clawback)
        ).toFixed(2),
      ),
      net_premium_to_insurer: Number(
        (
          (base.net_premium_to_insurer ?? 0) -
          Number(adjustment.total_insurer_credit)
        ).toFixed(2),
      ),
    },
  ];
}

import { describe, expect, it } from 'vitest';
import type { Policy } from '../types';
import { projectInsurerStatementPolicy } from './statementProjection';
const policy = {
  id: 'policy',
  insurer_id: 'A',
  gross_premium: 1000,
  commission_rate_pct: 10,
  commission_amount: 140,
  net_premium_to_insurer: 860,
  ins_policy_insurer_shares: [
    {
      insurer_id: 'A',
      premium_amount: 600,
      commission_rate_pct: 10,
      commission_amount: 60,
      payable_amount: 600,
    },
    {
      insurer_id: 'B',
      premium_amount: 400,
      commission_rate_pct: 20,
      commission_amount: 80,
      payable_amount: 410,
    },
  ],
} as unknown as Parameters<typeof projectInsurerStatementPolicy>[0];
describe('retained insurer statement projection', () => {
  it('keeps the selected non-lead insurer visible', () =>
    expect(projectInsurerStatementPolicy(policy, 'B')[0]).toMatchObject({
      insurer_id: 'B',
      gross_premium: 400,
      commission_amount: 80,
      net_premium_to_insurer: 410,
    }));
  it('subtracts only the selected insurer’s cancellation figures', () => {
    const p = {
      ...policy,
      ins_policy_cancellations: [
        {
          status: 'posted',
          calculation: {
            insurers: [
              {
                insurer_id: 'B',
                return_premium: '200',
                commission_clawback: '40',
                total_insurer_credit: '205',
              },
            ],
          },
        },
      ],
    };
    expect(projectInsurerStatementPolicy(p, 'B')[0]).toMatchObject({
      gross_premium: 200,
      commission_rate_pct: 20,
      commission_amount: 40,
      net_premium_to_insurer: 205,
    });
    expect(projectInsurerStatementPolicy(p, 'A')[0].gross_premium).toBe(600);
    expect(policy.gross_premium).toBe(1000);
  });
  it('does not treat a pending proposal as a financial credit', () =>
    expect(
      projectInsurerStatementPolicy(
        {
          ...policy,
          ins_policy_cancellations: [
            {
              status: 'prepared',
              calculation: {
                insurers: [
                  {
                    insurer_id: 'B',
                    return_premium: '400',
                    commission_clawback: '80',
                    total_insurer_credit: '410',
                  },
                ],
              },
            },
          ],
        },
        'B',
      )[0].gross_premium,
    ).toBe(400));
  it('does not invent a policy participation for another insurer', () =>
    expect(projectInsurerStatementPolicy(policy, 'C')).toEqual([]));
  it('preserves the old single-insurer projection without a cancellation', () => {
    const p = {
      ...policy,
      ins_policy_insurer_shares: [],
      commission_amount: 100,
      net_premium_to_insurer: 900,
    } as Policy;
    expect(projectInsurerStatementPolicy(p, 'A')).toEqual([p]);
  });
});

/** Read-only reference parity on a disposable local PostgreSQL database.
 * Run with Node 22; the local test owner needs access through sudo/postgres.
 * No remote/production connection or application authorization bypass is used.
 */
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import {
  allocatePassThroughRefund,
  calculateInsurerCancellation,
  cents,
  money,
  type InsurerCancellationTerms,
} from '../apps/web/src/modules/portals/insurance/cancellation/calculation.ts';
const database = process.env.PGDATABASE;
assert(
  database && /^[a-z][a-z0-9_]*_cash_test$/.test(database),
  'Set PGDATABASE to a disposable local *_cash_test database.',
);
const literal = (value: unknown) =>
  `'${JSON.stringify(value).replaceAll("'", "''")}'::jsonb`;
const query = (sql: string): unknown =>
  JSON.parse(
    execFileSync(
      'sudo',
      [
        '-u',
        'postgres',
        'psql',
        '-X',
        '-At',
        '-v',
        'ON_ERROR_STOP=1',
        '-d',
        database!,
      ],
      { input: sql, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 },
    ).trim(),
  );
const cases: {
  allocation: object;
  terms: InsurerCancellationTerms;
  effective: string;
  expected: ReturnType<typeof calculateInsurerCancellation>;
}[] = [];
for (const premium of [
  3n,
  247n,
  60000n,
  100000000000001n,
  999999999999999999n,
]) {
  for (const rate of [0n, 100000n, 200000n, 123456n, 999999n]) {
    const allocation = {
      insurer_id: 'A',
      premium_amount: money(premium),
      commission_amount: money((premium * rate * 2n + 1000000n) / 2000000n),
      commission_rate_pct: `${rate / 10000n}.${String(rate % 10000n).padStart(4, '0')}`,
    };
    for (const effective of [
      '2026-01-01',
      '2026-01-31',
      '2026-07-20',
      '2026-12-31',
      '2027-01-01',
    ]) {
      for (const terms of [
        {
          method: 'pro_rata',
          pro_rata_permitted: true,
          contract_reference: 'Contract permits pro-rata',
        },
        {
          method: 'short_period',
          contract_reference: 'Contract short-period schedule',
          short_period_bands: [
            { through_day: 30, retained_pct: '20' },
            { through_day: 210, retained_pct: '70' },
            { through_day: 365, retained_pct: '100' },
          ],
        },
        {
          method: 'non_refundable',
          contract_reference: 'Contract retains premium',
        },
      ] satisfies InsurerCancellationTerms[]) {
        const expected = calculateInsurerCancellation(allocation, terms, {
          inception: '2026-01-01',
          expiry: '2026-12-31',
          effective,
        });
        cases.push({ allocation, terms, effective, expected });
      }
    }
  }
}
const actual = query(
  `select jsonb_agg(platform_ins_calculate_insurer_cancellation(x->'allocation',x->'terms','2026-01-01','2026-12-31',(x->>'effective')::date) order by ord) from jsonb_array_elements(${literal(cases)}) with ordinality t(x,ord);`,
) as Record<string, unknown>[];
assert.equal(actual.length, cases.length);
for (const [i, c] of cases.entries()) {
  for (const [key, expected] of Object.entries(c.expected)) {
    const result = actual[i][key];
    if (
      [
        'original_premium',
        'retained_premium',
        'return_premium',
        'original_commission',
        'commission_clawback',
        'net_insurer_credit',
      ].includes(key)
    )
      assert.equal(
        cents(result as string),
        cents(expected as string),
        `case ${i}: ${key}`,
      );
    else assert.deepEqual(result, expected, `case ${i}: ${key}`);
  }
}
const allocations = [];
for (let a = 0n; a <= 12n; a++)
  for (let b = 0n; b <= 12n; b++)
    for (let r = 0n; r <= a + b; r++) {
      const original = [
        { insurer_id: 'A', amount: money(a) },
        { insurer_id: 'B', amount: money(b) },
      ];
      allocations.push({
        original,
        refund: money(r),
        expected: allocatePassThroughRefund(original, money(r)),
      });
    }
// Include values well beyond JavaScript's safe integer range.
for (const r of [1n, 100n, 9007199254740993n, 18014398509481985n]) {
  const original = [
    { insurer_id: 'B', amount: '90071992547409.92' },
    { insurer_id: 'A', amount: '90071992547409.93' },
  ];
  allocations.push({
    original,
    refund: money(r),
    expected: allocatePassThroughRefund(original, money(r)),
  });
}
const results = query(
  `select jsonb_agg(platform_ins_allocate_cancellation_refund(x->'original',x->>'refund') order by ord) from jsonb_array_elements(${literal(allocations)}) with ordinality t(x,ord);`,
) as { insurer_id: string; amount: string }[][];
assert.equal(results.length, allocations.length);
for (const [i, c] of allocations.entries())
  assert.deepEqual(
    results[i].map((x) => ({ ...x, amount: money(cents(x.amount)) })),
    c.expected,
    `allocation ${i}`,
  );
console.log(
  `PASS: ${cases.length} insurer calculations and ${allocations.length} exact-cent allocations match TypeScript and PostgreSQL.`,
);

/**
 * Real two-connection co-insurance PostgreSQL races; Node >=22.18, psql on PATH.
 * Run ONLY against a disposable, migrated local database named *_cash_test:
 *   PGDATABASE=coinsurance_cash_test PGUSER=postgres node scripts/test-ins-coinsurance-concurrency.ts
 * Uses the fixture prefix of test_ins_coinsurance_charges.sql, then COMMITs isolated test
 * tenants so independent connections can see them. Drop the test database after.
 * Never point this script at a hosted or production database.
 */
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const host = process.env.PGHOST ?? '';
assert(
  !process.env.PGSERVICE && !process.env.PGSERVICEFILE,
  'PGSERVICE overrides are not allowed',
);
assert(!process.env.PGHOSTADDR, 'PGHOSTADDR overrides are not allowed');
assert(
  !process.env.PGDATABASE?.includes('://'),
  'Use an explicit local database name, not a URL',
);
assert(
  /^[a-z0-9_]+_cash_test$/.test(process.env.PGDATABASE ?? ''),
  'PGDATABASE must name a disposable *_cash_test database',
);
assert(
  host === '' ||
    host === 'localhost' ||
    host === '127.0.0.1' ||
    host === '::1' ||
    host.startsWith('/'),
  'Only local PostgreSQL is allowed',
);
const args = ['-XqAt', '-v', 'ON_ERROR_STOP=1'];
const sql = (statement: string): string => {
  const p = spawnSync('psql', args, {
    input: statement,
    encoding: 'utf8',
    timeout: 30000,
  });
  assert.equal(p.status, 0, p.stderr || p.error?.message);
  return p.stdout.trim();
};
const quote = (s: string) => `'${s.replaceAll("'", "''")}'`;
const asUser = (id: string) =>
  `set local request.jwt.claims=${quote(JSON.stringify({ sub: id, role: 'authenticated' }))}; set local role authenticated;`;
interface Context {
  tenant: string;
  policy: string;
  bank: string;
  maker: string;
  checker: string;
  reconciler: string;
  receipt: string;
  first: string;
  second: string;
  line: string;
  third: string;
  share_a: string;
  share_b: string;
}
const marker = '-- COINSURANCE_FIXTURE_READY';
const source = readFileSync(
  new URL(
    '../supabase/tests/test_ins_coinsurance_charges.sql',
    import.meta.url,
  ),
  'utf8',
);
assert.equal(
  source.split(marker).length,
  2,
  'SQL fixture marker missing or duplicated',
);
function fixture(): Context {
  const output = sql(
    source.split(marker)[0] +
      `
    perform pg_temp.jwt(maker); set local role authenticated;
    q1:=ins_submit_policy_cash_request(draft.id,'receipt',trust,400,current_date,gen_random_uuid());
    q2:=ins_submit_policy_cash_request(draft.id,'receipt',trust,204.50,current_date,gen_random_uuid());
    perform pg_temp.jwt(checker); q1:=ins_decide_policy_cash_request(q1.id,'approve'); q2:=ins_decide_policy_cash_request(q2.id,'approve');
    perform pg_temp.jwt(maker);
    qa:=ins_submit_policy_share_cash_request(draft.id,a,trust,300,current_date,gen_random_uuid());
    qb:=ins_submit_policy_share_cash_request(draft.id,a,trust,300,current_date,gen_random_uuid());
    outq:=ins_submit_policy_share_cash_request(draft.id,b,trust,200,current_date,gen_random_uuid());
    select id into receipt_line from import_bank_statement_lines('PREMIUM-TRUST',jsonb_build_array(jsonb_build_object('statement_date',current_date,'amount',204.50)));
    reset role;
    perform set_config('ins_cash.test_context',json_build_object('tenant',ta,'policy',draft.id,'bank',trust,
      'maker',maker,'checker',checker,'reconciler',reconciler,'receipt',q2.settlement_id,'first',qa.id,'second',qb.id,'third',outq.id,'share_a',a,'share_b',b,'line',receipt_line)::text,true);
  end $$;
  select current_setting('ins_cash.test_context');
  commit;
  `,
  );
  return JSON.parse(
    output.split('\n').find((line) => line.startsWith('{'))!,
  ) as Context;
}
function session(statement: string) {
  const p = spawn('psql', args, { stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  const result = new Promise<{
    code: number | null;
    stdout: string;
    stderr: string;
  }>((resolve, reject) => {
    p.on('error', reject);
    p.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    p.stderr.on('data', (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    p.on('close', (code) => resolve({ code, stdout, stderr }));
  });
  const ready = new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      p.kill('SIGTERM');
      reject(new Error(`Session never acquired its lock: ${stderr}`));
    }, 15000);
    p.stdout.on('data', () => {
      if (stdout.includes('CASH_TEST_LOCK_HELD')) {
        clearTimeout(timer);
        resolve();
      }
    });
    p.on('close', () => {
      clearTimeout(timer);
      if (!stdout.includes('CASH_TEST_LOCK_HELD'))
        reject(new Error(stderr || 'Session closed before lock acquisition'));
    });
    p.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
  });
  // Callers that need only completion still consume a potential ready rejection.
  ready.catch(() => undefined);
  p.stdin.end(statement);
  return { result, ready };
}
async function race(first: string, second: string, error: string | null) {
  const a = session(
    `begin; set local lock_timeout='10s'; ${first}; select 'CASH_TEST_LOCK_HELD'; select pg_sleep(1); commit;`,
  );
  await a.ready;
  const b = session(`begin; set local lock_timeout='10s'; ${second}; commit;`);
  const [one, two] = await Promise.all([a.result, b.result]);
  assert.equal(one.code, 0, one.stderr);
  if (error === null) assert.equal(two.code, 0, two.stderr);
  else {
    assert.notEqual(two.code, 0, 'Competing operation unexpectedly succeeded');
    assert.match(two.stderr, new RegExp(error));
  }
}
const approve = (c: Context, id: string) =>
  `${asUser(c.checker)} select ins_decide_policy_cash_request(${quote(id)},'approve')`;
const voidReceipt = (c: Context) =>
  `${asUser(c.maker)} select fin_void_settlement(${quote(c.receipt)},'race test receipt reversal')`;
function position(c: Context) {
  return JSON.parse(
    sql(
      `begin; ${asUser(c.maker)} select ins_policy_cash_position(${quote(c.policy)}); rollback;`,
    )
      .split('\n')
      .find((s) => s.startsWith('{'))!,
  ) as { collected: number; remitted: number };
}

{
  const c = fixture();
  await race(approve(c, c.first), approve(c, c.second), 'INS_CASH_CAP');
  const p = position(c);
  assert.equal(Number(p.collected), 604.5);
  assert.equal(Number(p.remitted), 300);
  assert.equal(
    sql(
      `select status from ins_policy_cash_requests where id=${quote(c.second)}`,
    ),
    'pending',
  );
  console.log(
    'PASS: competing remittances cannot overspend the same allocated collections',
  );
}
{
  const c = fixture();
  await race(approve(c, c.first), approve(c, c.first), null);
  assert.equal(
    sql(
      `select count(*) from fin_settlements s join fin_allocations a on a.settlement_id=s.id join ins_policy_cash_items i on i.id=a.open_item_id where i.source_id=${quote(c.policy)} and s.direction='out'`,
    ),
    '1',
  );
  console.log(
    'PASS: concurrent retries of one approval create exactly one settlement',
  );
}
{
  const c = fixture();
  await race(approve(c, c.first), voidReceipt(c), 'INS_CASH_FUNDS_IN_USE');
  const p = position(c);
  assert.equal(Number(p.collected), 604.5);
  assert.equal(Number(p.remitted), 300);
  console.log(
    'PASS: winning remittance prevents concurrent void of its funding receipt',
  );
}
{
  const c = fixture();
  await race(voidReceipt(c), approve(c, c.first), 'INS_CASH_CAP');
  const p = position(c);
  assert.equal(Number(p.collected), 400);
  assert.equal(Number(p.remitted), 0);
  console.log(
    'PASS: winning receipt void prevents concurrent remittance approval',
  );
}
{
  const c = fixture();
  await race(
    `${asUser(c.reconciler)} select match_bank_statement_line_to_settlement(${quote(c.line)},${quote(c.receipt)})`,
    voidReceipt(c),
    'reconciled',
  );
  assert.equal(
    sql(
      `select count(*) from bank_reconciliations where settlement_id=${quote(c.receipt)}`,
    ),
    '1',
  );
  assert.equal(
    sql(`select status from fin_settlements where id=${quote(c.receipt)}`),
    'posted',
  );
  console.log(
    'PASS: independent bank match prevents concurrent settlement void',
  );
}
{
  const c = fixture();
  await race(approve(c, c.first), approve(c, c.third), null);
  const p = position(c);
  assert.equal(Number(p.remitted), 500);
  assert.equal(
    sql(
      `select sum(amount) from ins_policy_cash_requests where policy_id=${quote(c.policy)} and status='posted' and kind='remittance'`,
    ),
    '500.00',
  );
  console.log(
    'PASS: concurrent remittances to different insurers each respect their independent funded allocation',
  );
}
console.log(
  'All 6 two-session co-insurance races passed. Drop the disposable test database to remove committed fixtures.',
);

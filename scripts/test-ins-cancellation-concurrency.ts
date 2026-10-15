/**
 * Real two-connection cancellation approval PostgreSQL races; Node >=22.18, psql on PATH.
 * Run ONLY against a disposable, migrated local database named *_cash_test:
 *   PGDATABASE=coinsurance_cash_test PGUSER=postgres node scripts/test-ins-cancellation-concurrency.ts
 * Uses the fixture prefix of test_ins_cancellation_posting.sql, then COMMITs isolated test
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
  operating: string;
  maker: string;
  checker: string;
  reconciler: string;
  manager: string;
  cancellation: string;
  receipt: string;
  entry: string;
}
const marker = '-- CANCELLATION_POSTING_FIXTURE_READY';
const source = readFileSync(
  new URL(
    '../supabase/tests/test_ins_cancellation_posting.sql',
    import.meta.url,
  ),
  'utf8',
);
assert.equal(
  source.split(marker).length,
  2,
  'Cancellation fixture marker missing or duplicated',
);
function fixture(earned = false): Context {
  const extra = earned
    ? `
 perform pg_temp.jwt(maker); set local role authenticated;
 qa:=ins_submit_policy_share_cash_request(draft.id,a,trust,600,current_date,gen_random_uuid());
 perform pg_temp.jwt(checker); qa:=ins_decide_policy_cash_request(qa.id,'approve');
 perform pg_temp.jwt(maker); cancellation:=ins_prepare_policy_cancellation(cancellation.id,clearing);
 reset role;
 `
    : '';
  const output = sql(
    source.split(marker)[0] +
      extra +
      `
 perform set_config('ins_cancel.test_context',json_build_object('tenant',ta,'policy',draft.id,'bank',trust,'operating',operating,
  'maker',maker,'checker',checker,'reconciler',reconciler,'manager',manager,'cancellation',cancellation.id,'receipt',q.settlement_id,'entry',commission_a)::text,true);
 end $$;
 select current_setting('ins_cancel.test_context'); commit;
 `,
  );
  return JSON.parse(
    output.split('\n').find((s) => s.startsWith('{'))!,
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

const approve = (c: Context, checker = c.checker) =>
  `${asUser(checker)} select ins_decide_policy_cancellation(${quote(c.cancellation)},'approve','Reviewed cancellation race fixture',true)`;
const claim = (c: Context) =>
  `${asUser(c.manager)} select ins_create_claim(${quote(c.policy)},current_date,current_date,'Claim arriving during cancellation',null,100)`;
const voidReceipt = (c: Context) =>
  `${asUser(c.maker)} select fin_void_settlement(${quote(c.receipt)},'Receipt correction racing cancellation')`;
const transfer = (c: Context) =>
  `${asUser(c.manager)} select ins_transfer_earned_commission(${quote(c.bank)},${quote(c.operating)},current_date,array[${quote(c.entry)}::uuid],'Commission transfer racing cancellation')`;
const status = (c: Context) =>
  sql(
    `select status from ins_policy_cancellations where id=${quote(c.cancellation)}`,
  );
{
  const c = fixture();
  await race(approve(c), approve(c), null);
  assert.equal(status(c), 'posted');
  assert.equal(
    sql(
      `select count(*) from ins_policy_cancellations where policy_id=${quote(c.policy)} and status='posted'`,
    ),
    '1',
  );
  assert.equal(
    sql(
      `select count(*) from fin_open_items where source_type='ins_cancellation_client_refund' and source_id=${quote(c.cancellation)}`,
    ),
    '1',
  );
  console.log(
    'PASS: duplicate approval retries create one cancellation and one refund liability',
  );
}
{
  const c = fixture();
  await race(approve(c), approve(c, c.reconciler), 'INS_CANCELLATION_STATE');
  assert.equal(status(c), 'posted');
  console.log(
    'PASS: competing Finance checkers cannot post a second cancellation',
  );
}
{
  const c = fixture();
  await race(voidReceipt(c), approve(c), 'INS_CANCELLATION_STALE');
  assert.equal(status(c), 'prepared');
  console.log(
    'PASS: receipt void winning invalidates the prepared financial review',
  );
}
{
  const c = fixture();
  await race(approve(c), voidReceipt(c), 'INS_CANCELLATION_LOCKED');
  assert.equal(status(c), 'posted');
  assert.equal(
    sql(`select status from fin_settlements where id=${quote(c.receipt)}`),
    'posted',
  );
  console.log('PASS: cancellation winning preserves its original cash history');
}
{
  const c = fixture();
  await race(claim(c), approve(c), 'INS_CANCELLATION_CLAIM');
  assert.equal(status(c), 'prepared');
  console.log('PASS: claim winning blocks cancellation approval');
}
{
  const c = fixture();
  await race(
    approve(c),
    claim(c),
    'INS_POLICY_UNAVAILABLE|INS_CLAIM_POLICY|INS_POLICY_NOT_BOUND',
  );
  assert.equal(status(c), 'posted');
  assert.equal(
    sql(`select count(*) from ins_claims where policy_id=${quote(c.policy)}`),
    '0',
  );
  console.log(
    'PASS: cancellation winning blocks a new claim through the existing policy lock',
  );
}
{
  const c = fixture(true);
  await race(transfer(c), approve(c), 'INS_CANCELLATION_STALE');
  assert.equal(status(c), 'prepared');
  console.log(
    'PASS: commission transfer winning invalidates the prepared accounting position',
  );
}
{
  const c = fixture(true);
  await race(
    approve(c),
    transfer(c),
    'INS_TRANSFER_NOTHING|INS_TRANSFER_ENTRIES',
  );
  assert.equal(status(c), 'posted');
  console.log(
    'PASS: cancellation winning prevents transfer of original unadjusted commission',
  );
}
console.log(
  'All 8 two-session cancellation approval races passed. Drop the disposable database to remove committed fixtures.',
);

/**
 * Real two-connection cancellation cash PostgreSQL races; Node >=22.18, psql on PATH.
 * Run ONLY against a disposable, migrated local database named *_cash_test:
 *   PGDATABASE=coinsurance_cash_test PGUSER=postgres node scripts/test-ins-cancellation-cash-concurrency.ts
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
  cancellation: string;
  adjustment: string;
  receipt: string;
  receipt_match: string;
  bank_gl: string;
  operating_gl: string;
}
const source = readFileSync(
  new URL('../supabase/tests/test_ins_cancellation_cash.sql', import.meta.url),
  'utf8',
);
const marker = '-- CANCELLATION_CASH_FIXTURE_READY';
assert.equal(source.split(marker).length, 2);
function fixture(): Context {
  const output = sql(
    source.split(marker)[0] +
      `
 perform pg_temp.jwt(checker); set local role authenticated;
 cancellation:=ins_decide_policy_cancellation(cancellation.id,'approve','Reviewed cash concurrency fixture',true);
 perform pg_temp.jwt(reconciler);
 for q in select r.* from ins_policy_cash_requests r where r.policy_id=draft.id and r.kind='receipt' and r.status='posted' loop perform pg_temp.cash_match(q.settlement_id); end loop;
 reset role;
 perform set_config('ins_cxl_cash.fixture',json_build_object('tenant',ta,'policy',draft.id,'bank',trust,'operating',operating,'maker',maker,'checker',checker,'reconciler',reconciler,'cancellation',cancellation.id,
 'adjustment',(select id from ins_cancellation_insurer_adjustments where cancellation_id=cancellation.id and insurer_id=insurer),
 'receipt',q.settlement_id,'receipt_match',(select id from bank_reconciliations where settlement_id=q.settlement_id),'bank_gl',trust_gl,'operating_gl',bank_gl)::text,true);
 end $$; select current_setting('ins_cxl_cash.fixture'); commit;
 `,
  );
  return JSON.parse(
    output.split('\n').find((s) => s.startsWith('{'))!,
  ) as Context;
}
function proposal(c: Context, kind = 'refund', amount = '100'): string {
  return sql(
    `begin; ${asUser(c.maker)} select (ins_submit_cancellation_cash(${quote(c.cancellation)},${quote(kind)},${kind === 'remittance' ? quote(c.adjustment) : 'null'},${quote(c.bank)},null,${amount},current_date,'RACE-CASH','Verified race cash purpose',gen_random_uuid())).id; commit;`,
  )
    .split('\n')
    .find((s) => /^[0-9a-f-]{36}$/.test(s))!;
}
const approve = (c: Context, id: string, actor = c.checker) =>
  `${asUser(actor)} select ins_decide_cancellation_cash(${quote(id)},'approve','Independent race review')`;
const unmatch = (c: Context) =>
  `${asUser(c.reconciler)} select unmatch_bank_reconciliation(${quote(c.receipt_match)})`;
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

{
  const c = fixture(),
    id = proposal(c);
  await race(approve(c, id), approve(c, id), null);
  assert.equal(
    sql(
      `select count(*) from fin_settlements where id=(select settlement_id from ins_cancellation_cash_requests where id=${quote(id)})`,
    ),
    '1',
  );
  console.log(
    'PASS: duplicate checker retry posts exactly one refund settlement',
  );
}
{
  const c = fixture(),
    id = proposal(c);
  await race(
    approve(c, id),
    approve(c, id, c.reconciler),
    'INS_CXL_CASH_STATE',
  );
  console.log('PASS: different checkers cannot both approve one cash request');
}
{
  const c = fixture(),
    a = proposal(c, 'refund', '400'),
    b = proposal(c, 'refund', '400');
  await race(approve(c, a), approve(c, b), 'INS_CXL_CASH_FUNDS');
  console.log(
    'PASS: competing refunds cannot consume more than refund liability',
  );
}
{
  const c = fixture(),
    a = proposal(c, 'remittance', '300'),
    b = proposal(c, 'remittance', '300');
  await race(approve(c, a), approve(c, b), 'INS_CXL_CASH_FUNDS');
  console.log(
    'PASS: competing insurer remittances cannot overpay retained liability',
  );
}
for (const reverse of [false, true]) {
  const c = fixture(),
    a = proposal(c, 'refund', '604.5'),
    b = proposal(c, 'remittance', '300');
  await race(approve(c, reverse ? b : a), approve(c, reverse ? a : b), null);
  console.log(
    'PASS: refund and retained remittance both preserve all reserves in ' +
      (reverse ? 'remittance-first' : 'refund-first') +
      ' order',
  );
}
{
  const c = fixture(),
    id = proposal(c);
  await race(approve(c, id), unmatch(c), 'INS_CXL_CASH_FUNDS_IN_USE');
  console.log(
    'PASS: winning refund locks its actual incoming funding evidence',
  );
}
{
  const c = fixture(),
    id = proposal(c);
  await race(unmatch(c), approve(c, id), 'INS_CXL_CASH_FUNDS');
  console.log('PASS: winning unmatch prevents a refund using unproven funds');
}
for (const matchFirst of [true, false]) {
  const c = fixture(),
    id = proposal(c);
  sql(`begin; ${approve(c, id)}; commit;`);
  const vid = sql(
    `begin; ${asUser(c.maker)} select(ins_submit_cancellation_cash_void(${quote(id)},'Correction racing reconciliation',gen_random_uuid())).id; commit;`,
  )
    .split('\n')
    .find((s) => /^[0-9a-f-]{36}$/.test(s))!;
  const line = sql(
    `begin; ${asUser(c.reconciler)} select id from import_bank_statement_lines('PREMIUM-TRUST',jsonb_build_array(jsonb_build_object('statement_date',current_date,'amount',-100))); commit;`,
  )
    .split('\n')
    .find((s) => /^[0-9a-f-]{36}$/.test(s))!;
  const matching = `${asUser(c.reconciler)} select match_bank_statement_line_to_settlement(${quote(line)},(select settlement_id from ins_cancellation_cash_requests where id=${quote(id)}))`;
  await race(
    matchFirst ? matching : approve(c, vid),
    matchFirst ? approve(c, vid) : matching,
    matchFirst ? 'INS_CXL_CASH_MATCHED' : 'only posted settlements',
  );
  console.log(
    'PASS: ' +
      (matchFirst
        ? 'bank matching prevents correction void'
        : 'correction void prevents a stale bank match'),
  );
}
{
  const c = fixture(),
    id = proposal(c);
  const depletion = `set local request.jwt.claims=${quote(JSON.stringify({ sub: c.checker, role: 'authenticated' }))}; select post_journal_entry(${quote(c.tenant)},'manual',gen_random_uuid(),current_date,'Bank depletion racing refund',jsonb_build_array(jsonb_build_object('gl_account_id',${quote(c.operating_gl)},'debit',1209),jsonb_build_object('gl_account_id',${quote(c.bank_gl)},'credit',1209)))`;
  await race(depletion, approve(c, id), 'INS_CXL_CASH_FUNDS');
  console.log(
    'PASS: concurrent manual bank book reduction is visible before refund approval',
  );
}
for (const withdrawalFirst of [true, false]) {
  const c = fixture(),
    remit = proposal(c, 'remittance', '300');
  sql(`begin; ${approve(c, remit)}; commit;`);
  const withdrawal = sql(
    `begin; ${asUser(c.maker)} select(ins_submit_cancellation_cash(${quote(c.cancellation)},'commission_withdrawal',${quote(c.adjustment)},${quote(c.bank)},${quote(c.operating)},30,current_date,'NET-COMMISSION','Verified retained commission',gen_random_uuid())).id; commit;`,
  )
    .split('\n')
    .find((x) => /^[0-9a-f-]{36}$/.test(x))!;
  const vid = sql(
    `begin; ${asUser(c.maker)} select(ins_submit_cancellation_cash_void(${quote(remit)},'Correct retained remittance booking',gen_random_uuid())).id; commit;`,
  )
    .split('\n')
    .find((x) => /^[0-9a-f-]{36}$/.test(x))!;
  await race(
    approve(c, withdrawalFirst ? withdrawal : vid),
    approve(c, withdrawalFirst ? vid : withdrawal),
    withdrawalFirst ? 'INS_CXL_CASH_FUNDS_IN_USE' : 'INS_CXL_CASH_FUNDS',
  );
  console.log(
    'PASS: ' +
      (withdrawalFirst
        ? 'retained commission withdrawal prevents voiding its funded remittance'
        : 'remittance void prevents withdrawal of unearned retained commission'),
  );
}
console.log(
  'All 13 real two-session cancellation cash races passed. Drop the disposable database to remove committed fixtures.',
);

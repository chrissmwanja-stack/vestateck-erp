/**
 * Two real connections racing each other through ins_transfer_earned_commission.
 *
 * This exists because of one specific claim, recorded in ACCOUNTANT_PACK.md §16.3 as AE1:
 * that concurrent commission transfers serialise on the policies that have earned commission,
 * so two of them cannot each read a sufficient free client-money position and together
 * overdraw the account.
 *
 * A single-session test cannot demonstrate that. It passes whether the lock is present or
 * absent, which makes it the wrong instrument for the question. This file is the right one.
 *
 * NOT YET RUN. Be clear about that rather than assuming otherwise:
 *   - it needs two independent psql connections, which the environment this branch was
 *     verified in did not have;
 *   - it needs Node >= 22.18 for native TypeScript, and that environment had Node 20;
 *   - it needs a disposable local database with the full migration chain applied.
 * Until it runs, the lock is correct by reading and by PostgreSQL's documented semantics for
 * SELECT ... FOR UPDATE, and unproven by execution. Do not upgrade AE1 on the strength of
 * the code alone.
 *
 * Run ONLY against a disposable, migrated local database named *_transfer_test:
 *
 *   createdb accountant_pack_transfer_test
 *   supabase db push                     # or replay supabase/migrations into it
 *   PGDATABASE=accountant_pack_transfer_test PGUSER=postgres \
 *     node scripts/test-ins-commission-transfer-concurrency.ts
 *   dropdb accountant_pack_transfer_test
 *
 * Never point this at a hosted or production database. The guards below refuse anything that
 * is not obviously a local scratch database, on purpose.
 */
import { spawn, spawnSync } from 'node:child_process';
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
  /^[a-z0-9_]+_transfer_test$/.test(process.env.PGDATABASE ?? ''),
  'PGDATABASE must name a disposable *_transfer_test database',
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
  manager: string;
  trust_bank: string;
  ops_bank: string;
  entry_a: string;
  entry_b: string;
  fee_purpose: string;
}

/**
 * Build the fixture and COMMIT it, so two independent connections can both see it.
 * Free client money is set to exactly 100,000 and two earned entries of 100,000 each exist:
 * the second transfer must therefore find nothing left. That is the whole test.
 */
function fixture(): Context {
  const out = sql(`
begin;
do $$
declare
  ta uuid := gen_random_uuid();
  mgr uuid := gen_random_uuid();
  trust_gl uuid; ops_gl uuid; eq_gl uuid; pay_gl uuid; ins_gl uuid;
  trust_bank uuid; ops_bank uuid;
  party uuid; supplier uuid; line uuid; insurer uuid;
  policy uuid; entry_a uuid; entry_b uuid;
begin
  insert into tenants(id, name) values (ta, 'Commission transfer race');
  insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data, aud, role, created_at, updated_at)
    values (mgr, 'ctr-race@test.local', '{}', '{}', 'authenticated', 'authenticated', now(), now());
  insert into app_users(id, tenant_id, name, email)
    values (mgr, ta, 'Race manager', 'ctr-race@test.local');
  update app_users set is_company_admin = true where id = mgr;
  insert into tenant_modules(tenant_id, module) values (ta, 'insurance');
  insert into staff_roles(tenant_id, user_id, module, role) values (ta, mgr, 'insurance', 'manager');
  insert into finance_team_members(tenant_id, user_id, role) values (ta, mgr, 'finance');

  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '1020', 'Client money', 'asset') returning id into trust_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '1000', 'Operating', 'asset') returning id into ops_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '3200', 'Retained earnings', 'equity') returning id into eq_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '2010', 'Insurer payable', 'liability') returning id into pay_gl;
  insert into gl_accounts(tenant_id, account_code, name, account_type)
    values (ta, '2020', 'Unearned commission', 'liability') returning id into ins_gl;
  insert into gl_posting_rules(tenant_id, account_role, gl_account_id) values
    (ta, 'client_money_bank', trust_gl), (ta, 'bank', ops_gl),
    (ta, 'insurer_payable', pay_gl), (ta, 'unearned_commission', ins_gl),
    (ta, 'commission_income', ins_gl);

  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'CTR-TRUST', 'client_money', 'UGX', trust_gl) returning id into trust_bank;
  insert into fin_bank_accounts(tenant_id, name, kind, currency, gl_account_id)
    values (ta, 'CTR-OPS', 'operating', 'UGX', ops_gl) returning id into ops_bank;

  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'RACE-CLI', 'Race client', 'client') returning id into party;
  insert into accounts(tenant_id, account_code, name, account_type) values (ta, 'RACE-SUP', 'Race supplier', 'vendor') returning id into supplier;
  insert into ins_product_lines(tenant_id, code, name) values (ta, 'GEN', 'General') returning id into line;
  insert into ins_insurers(tenant_id, code, name) values (ta, 'RACE', 'Race Insurer') returning id into insurer;
  insert into bd_clients(tenant_id, name) values (ta, 'Race client');
  insert into ins_clients(tenant_id, client_id, client_type, party_account_id)
    select ta, id, 'corporate', party from bd_clients where tenant_id = ta and name = 'Race client';

  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_policies(tenant_id, policy_no, client_id, insurer_id, product_line_id,
                           inception_date, expiry_date, sum_insured, gross_premium,
                           currency, status, transaction_type)
  select ta, 'RACE-1', c.id, insurer, line, current_date, current_date + 365, 1000000, 1000000,
         'UGX', 'active', 'new_business'
    from ins_clients c where c.tenant_id = ta
   returning id into policy;

  -- Client money funded to exactly 100,000, with nothing owed against it. The credit side
  -- goes to equity rather than AP control: a credit on a control account would itself be an
  -- open item, and the position would start negative, which is not what this race is about.
  perform public.post_journal_entry(ta, 'opening_balance', null, public.ins_local_today(),
    'client money funded', jsonb_build_array(
      jsonb_build_object('gl_account_id', trust_gl, 'debit', 100000),
      jsonb_build_object('gl_account_id', eq_gl,    'credit', 100000)));

  -- ins_commission_entries has no currency column; the currency comes from the policy.
  insert into ins_commission_entries(tenant_id, policy_id, amount, status, earned_on)
    values (ta, policy, 100000, 'earned', public.ins_local_today()) returning id into entry_a;
  insert into ins_commission_entries(tenant_id, policy_id, amount, status, earned_on)
    values (ta, policy, 100000, 'earned', public.ins_local_today()) returning id into entry_b;

  perform set_config('ctr_race.fixture', json_build_object(
    'tenant', ta, 'manager', mgr,
    'trust_bank', trust_bank, 'ops_bank', ops_bank,
    'entry_a', entry_a, 'entry_b', entry_b,
    'fee_purpose', 'commission transfer race fixture')::text, true);
end $$;
select current_setting('ctr_race.fixture');
commit;
`);
  return JSON.parse(
    out.split('\n').find((s) => s.startsWith('{'))!,
  ) as Context;
}

const transfer = (c: Context, entry: string) =>
  `${asUser(c.manager)} select (public.ins_transfer_earned_commission(` +
  `${quote(c.trust_bank)},${quote(c.ops_bank)},public.ins_local_today(),` +
  `array[${quote(entry)}]::uuid[],'race')) .id;`;

/**
 * Session A's own transfer takes the lock and holds it until it commits, so no artificial
 * lock is needed: the competing session is blocked by the real work, which is the situation
 * being tested. (An earlier draft of this file tried to take the lock explicitly with
 * `perform ... for update` in a plain session; `perform` is plpgsql-only and does not exist
 * at the SQL prompt. It is deleted rather than worked around.)
 */
const holder = (c: Context, entry: string) =>
  `begin; set local lock_timeout='10s'; ${transfer(c, entry)} ` +
  `select 'CTR_RACE_LOCK_HELD'; select pg_sleep(1); commit;`;

interface Session {
  result: Promise<{ code: number | null; stdout: string; stderr: string }>;
  ready: Promise<void>;
}

function session(statement: string): Session {
  const p = spawn('psql', args, { stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  const result = new Promise<{ code: number | null; stdout: string; stderr: string }>(
    (resolve, reject) => {
      p.on('error', reject);
      p.stdout.on('data', (chunk: Buffer) => {
        stdout += chunk.toString();
      });
      p.stderr.on('data', (chunk: Buffer) => {
        stderr += chunk.toString();
      });
      p.on('close', (code) => resolve({ code, stdout, stderr }));
    },
  );
  const ready = new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      p.kill('SIGTERM');
      reject(new Error(`Session never acquired its lock: ${stderr}`));
    }, 15000);
    p.stdout.on('data', () => {
      if (stdout.includes('CTR_RACE_LOCK_HELD')) {
        clearTimeout(timer);
        resolve();
      }
    });
    p.on('close', () => {
      clearTimeout(timer);
      if (!stdout.includes('CTR_RACE_LOCK_HELD'))
        reject(new Error(stderr || 'Session closed before lock acquisition'));
    });
    p.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
  });
  ready.catch(() => undefined);
  p.stdin.end(statement);
  return { result, ready };
}

/**
 * Run `first` holding the lock, then `second` competing for it.
 * Returns both outcomes so the caller can assert on the accounting result, not just the exit
 * code: "the second one failed" is much weaker than "the second one was refused because the
 * money was gone".
 */
async function race(first: string, second: string) {
  const a = session(
    `begin; set local lock_timeout='10s'; ${first}; select 'CTR_RACE_LOCK_HELD'; select pg_sleep(1); commit;`,
  );
  await a.ready;
  const started = Date.now();
  const b = session(`begin; set local lock_timeout='10s'; ${second}; commit;`);
  const [one, two] = await Promise.all([a.result, b.result]);
  return { one, two, waited: Date.now() - started };
}

// ---------------------------------------------------------------------------
// §1 one transfer, no competition. Sanity, not evidence about the lock.
// ---------------------------------------------------------------------------
{
  const c = fixture();
  const r = sql(`begin; set local role authenticated; ${transfer(c, c.entry_a)} commit;`);
  assert.match(r, /[0-9a-f-]{36}/, `a lone transfer should succeed, got: ${r}`);
  console.log('PASS §1 a lone transfer succeeds');
}

// ---------------------------------------------------------------------------
// §2 THE TEST. Two transfers, one pot of 100,000, each asking for 100,000.
//
// Session A takes the policy lock, transfers entry A and commits. Session B is already
// waiting on that lock when it enters the function; once A commits, B reads the position A
// left behind and must be refused.
//
// Without the lock, B reads the position BEFORE A has taken anything -- 100,000, still
// enough -- and both post. The account ends 100,000 overdrawn and nothing anywhere reports a
// shortage, because each transfer was individually correct.
// ---------------------------------------------------------------------------
{
  const c = fixture();
  const { one, two, waited } = await race(
    transfer(c, c.entry_a),
    transfer(c, c.entry_b),
  );

  // The competing session had to wait: that is the serialisation itself.
  assert.ok(
    waited >= 900,
    `the second transfer should have waited on the lock for about a second, waited ${waited}ms -- ` +
      'if it completed immediately, nothing serialised it',
  );
  assert.equal(one.code, 0, `session A should have succeeded: ${one.stderr}`);
  assert.notEqual(two.code, 0, 'the second transfer must not take the last of the client money');
  assert.match(
    two.stderr,
    /INS_TRANSFER_POSITION/,
    `expected INS_TRANSFER_POSITION, got: ${two.stderr}`,
  );

  // And the ledger agrees with the refusal: exactly one transfer posted.
  const posted = sql(
    `select count(*) from ins_commission_transfers where transfer_no is not null ` +
      `and tenant_id=${quote(c.tenant)};`,
  );
  assert.equal(posted, '1', `exactly one transfer should have posted, found ${posted}`);

  const stillEarned = sql(
    `select count(*) from ins_commission_entries where tenant_id=${quote(c.tenant)} and status='earned';`,
  );
  assert.equal(stillEarned, '1', 'the refused transfer must leave its commission entry untouched');

  const free = sql(
    `select public.platform_ins_client_money_free(${quote(c.tenant)}, 'UGX');`,
  );
  assert.ok(
    !free.startsWith('-'),
    `the client-money position must not be negative after the race, got ${free}`,
  );

  console.log(
    'PASS §2 two competing transfers cannot both take the last of the client money, ' +
      `and one entry stays earned (waited ${waited}ms)`,
  );
}

// ---------------------------------------------------------------------------
// §3 the permitted path still works afterwards: the pot refilled, the remaining entry
// transfers cleanly. A lock that refuses everything would pass §2 and fail here.
// ---------------------------------------------------------------------------
{
  const c = fixture();
  await race(
    transfer(c, c.entry_a),
    transfer(c, c.entry_b),
  );

  sql(
    `begin; select public.post_journal_entry(${quote(c.tenant)}, 'opening_balance', null,
       public.ins_local_today(), 'refill client money', jsonb_build_array(
         jsonb_build_object('gl_account_id',
           (select gl_account_id from fin_bank_accounts where id=${quote(c.trust_bank)}), 'debit', 100000),
         jsonb_build_object('gl_account_id',
           (select id from gl_accounts where tenant_id=${quote(c.tenant)} and account_code='3200'), 'credit', 100000)));
     commit;`,
  );

  const r = sql(`begin; set local role authenticated; ${transfer(c, c.entry_b)} commit;`);
  assert.match(
    r,
    /[0-9a-f-]{36}/,
    `with the pot refilled the remaining entry should transfer cleanly, got: ${r}`,
  );
  console.log('PASS §3 once the money is there, the remaining entry transfers cleanly');
}

console.log(
  '\nALL PASS: the transfer guard serialises competing transfers, refuses the second ' +
    'against the position the first left behind, and still lets a funded transfer through.',
);

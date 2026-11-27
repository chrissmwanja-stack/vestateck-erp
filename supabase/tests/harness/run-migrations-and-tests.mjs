#!/usr/bin/env node
// =====================================================================
// Applies every migration to an empty database, then runs the named test files.
// Accountant pack v2 -- the runner that produced docs/insurance-brokerage/EXECUTION_LOG.md
// =====================================================================
// WHY THIS EXISTS
//
//   Every claim in the pack is supposed to rest on evidence. Until now the evidence was
//   mostly SQL that had been written and parse-checked. Parse-checking proves a file is
//   syntactically valid SQL; it does not prove it runs. It does not even find a syntax error
//   inside a dollar-quoted function body, which is where five of the defects below were
//   living. The tests in this directory are psql scripts -- one transaction, rolled back,
//   `\set ON_ERROR_STOP on` -- so they need a PostgreSQL to run against and no psql binary is
//   available in this environment.
//
//   @electric-sql/pglite is real PostgreSQL compiled to WebAssembly (version 19.0 on
//   wasm32 at the time of writing). It is a genuine server -- the same parser, planner,
//   executor, plpgsql compiler and catalogs -- running in-process, so a test file executes
//   unchanged apart from the psql meta-command on its first line.
//
//   npm --no-save --prefix . install @electric-sql/pglite
//   node supabase/tests/harness/run-migrations-and-tests.mjs \
//        test_fin_manual_journal_chain test_client_money_controls
//
// WHAT IT PROVES, AND WHAT IT DOES NOT
//
//   It proves: every migration applies in order to an empty database; every statement of
//   the named test files executes; and no assertion in them raises.
//
//   It does NOT prove the application completes a workflow, nor that the deployed database
//   is configured like this one, nor user acceptance. The pack's acceptance_evidence rows
//   say which of those is claimed. Do not upgrade a claim because this script passed.
//
// SHIMS -- and they are not cosmetic
//
//   This build ships only the plpgsql extension. HARNESS SHIMS below are the complete,
//   enumerated list of differences from a Supabase database. Every one is a widening of what
//   the database permits or a stand-in for something absent; none of them adds a control.
//   Anything a migration or test relies on that is NOT in this list is real.
// =====================================================================

import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { PGlite } = require('@electric-sql/pglite');

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../../..');
const MIGRATIONS = join(ROOT, 'supabase/migrations');

// ---------------------------------------------------------------------
// HARNESS SHIMS
// ---------------------------------------------------------------------
// 1. Extensions this build does not ship. The CREATE EXTENSION line is removed, and the
//    removal is COUNTED and printed -- an omission that is not reported is a lie.
// 2. approval_delegations_no_overlap: the one gist EXCLUDE constraint, which needs
//    btree_gist. Dropped, and named in the output.
// 3. prelude.sql: roles, the `auth` schema (uid/role/jwt/users/mfa_factors), storage
//    objects/buckets, and pg_cron's schema as ORDINARY TABLES with schedule/unschedule
//    stubs, because migrations query cron.job and one of them schedules a job. Nothing
//    actually runs on a timer. Folders: auth.uid() reads the same GUC Supabase uses.
// 4. Test-file adaptation: the leading `\set ON_ERROR_STOP on` is removed. Nothing else in
//    any test file is rewritten.
const UNAVAILABLE_EXTENSIONS = [
  /^CREATE EXTENSION IF NOT EXISTS btree_gist[^;]*;/mi,
  /^CREATE EXTENSION IF NOT EXISTS pg_cron[^;]*;/mi,
  /^CREATE EXTENSION IF NOT EXISTS pg_stat_statements[^;]*;/mi,
  /^CREATE EXTENSION IF NOT EXISTS pgcrypto[^;]*;/mi,
  /^CREATE EXTENSION IF NOT EXISTS "uuid-ossp"[^;]*;/mi,
];
const DROPPED_CONSTRAINTS = [
  /ALTER TABLE ONLY public\.approval_delegations\s+ADD CONSTRAINT approval_delegations_no_overlap EXCLUDE USING gist[^;]*;/mi,
];

// Split a psql script into top-level statements, respecting dollar quotes, single quotes and
// line comments. This exists because this build surfaces neither NOTICE nor a reliable line
// number, so "which statement failed" has to be worked out from the statements themselves.
function splitStatements(sql) {
  const out = [];
  let buf = '';
  let i = 0;
  while (i < sql.length) {
    const c = sql[i];
    if (c === '$') {
      const m = /^\$[A-Za-z_]*\$/.exec(sql.slice(i));
      if (m) {
        const tag = m[0];
        const end = sql.indexOf(tag, i + tag.length);
        if (end < 0) {
          buf += sql.slice(i);
          break;
        }
        buf += sql.slice(i, end + tag.length);
        i = end + tag.length;
        continue;
      }
    }
    if (c === "'") {
      let j = i + 1;
      while (j < sql.length) {
        if (sql[j] === "'" && sql[j + 1] === "'") {
          j += 2;
          continue;
        }
        if (sql[j] === "'") {
          j++;
          break;
        }
        j++;
      }
      buf += sql.slice(i, j);
      i = j;
      continue;
    }
    if (c === '-' && sql[i + 1] === '-') {
      let j = sql.indexOf('\n', i);
      if (j < 0) j = sql.length;
      buf += sql.slice(i, j);
      i = j;
      continue;
    }
    if (c === ';') {
      out.push(buf + ';');
      buf = '';
      i++;
      continue;
    }
    buf += c;
    i++;
  }
  if (buf.trim()) out.push(buf);
  return out.map((s) => s.trim()).filter(Boolean);
}

async function main() {
  const tests = process.argv.slice(2);
  const db = await PGlite.create();
  const shims = new Set();

  await db.exec(readFileSync(join(HERE, 'prelude.sql'), 'utf8'));

  const files = readdirSync(MIGRATIONS).filter((f) => f.endsWith('.sql')).sort();
  let applied = 0;
  for (const f of files) {
    let sql = readFileSync(join(MIGRATIONS, f), 'utf8');
    for (const re of UNAVAILABLE_EXTENSIONS) {
      if (re.test(sql)) {
        shims.add(`extension removed from ${f}`);
        sql = sql.replace(re, '');
      }
    }
    for (const re of DROPPED_CONSTRAINTS) {
      if (re.test(sql)) {
        shims.add(`approval_delegations_no_overlap (needs btree_gist) dropped from ${f}`);
        sql = sql.replace(re, '');
      }
    }
    try {
      await db.exec(sql);
      applied++;
    } catch (e) {
      console.error(`FAILED migration ${f}\n  [${e.code}] ${(e.message || '').split('\n')[0]}`);
      process.exit(1);
    }
  }
  const v = (await db.query('select version() v')).rows[0].v;
  console.log(`migrations: ${applied}/${files.length} applied to an empty database`);
  console.log(`database:   ${v}`);
  for (const s of shims) console.log(`shim:       ${s}`);

  // ---- seed.sql ---------------------------------------------------------
  // `supabase start` replays supabase/seed.sql after the migrations, so a defect that only
  // the seed provokes makes the whole CI job fail -- which is exactly what happened, and
  // this runner did not replay the seed, so it could not have seen it. Opt out with
  // HARNESS_SKIP_SEED=1 when you deliberately want migrations only.
  if (process.env.HARNESS_SKIP_SEED !== '1') {
    const seedPath = join(ROOT, 'supabase/seed.sql');
    const seedRaw = readFileSync(seedPath, 'utf8').replace(/^\\(set|echo).*$/gm, '');
    const seedStmts = splitStatements(seedRaw);
    for (let k = 0; k < seedStmts.length; k++) {
      try {
        await db.exec(seedStmts[k]);
      } catch (e) {
        console.error(`FAILED seed.sql (statement ${k + 1}/${seedStmts.length})`);
        console.error(`  [${e.code}] ${(e.message || '').split('\n')[0]}`);
        // `detail` is where PostgreSQL names the offending row / value for a CHECK or FK
        // violation. Without it a 23514 says only that some row was bad.
        if (e.detail) console.error(`  detail: ${String(e.detail).split('\n').slice(0, 4).join(' | ')}`);
        if (e.constraint) console.error(`  constraint: ${e.constraint}`);
        if (e.where) console.error(`  where: ${String(e.where).split('\n').slice(0, 2).join(' | ')}`);
        console.error(
          `  statement: ${JSON.stringify(
            seedStmts[k]
              .split('\n')
              .filter((l) => !l.trim().startsWith('--'))
              .join(' ')
              .slice(0, 300)
          )}`
        );
        process.exit(1);
      }
    }
    console.log(`seed:       ${seedStmts.length} statement(s) applied`);
  }

  let failed = 0;
  for (const t of tests) {
    const file = t.endsWith('.sql') ? t : `${t}.sql`;
    const vars = new Map();
    const rawFile = readFileSync(join(ROOT, 'supabase/tests', file), 'utf8');
    for (const m of rawFile.matchAll(/^\\set\s+([A-Za-z_][A-Za-z0-9_]*)\s+'''([^']*)'''\s*$/gm)) {
      vars.set(m[1], `'${m[2]}'`);
    }
    const raw = rawFile
      .replace(/^\\(set|echo).*$/gm, '')
      .replace(/^([^\n;]+?)\\gset\s*$/gm, '$1 /*__GSET__*/;');
    const stmts = splitStatements(raw);
    let broke = -1;
    let err = null;
    for (let k = 0; k < stmts.length; k++) {
      let sqlStmt = stmts[k];
      if (vars.size > 0) {
        sqlStmt = sqlStmt
          .replace(/:'([A-Za-z_][A-Za-z0-9_]*)'/g, (full, name) => (vars.has(name) ? `'${vars.get(name)}'` : full))
          .replace(/(?<![:\w]):([A-Za-z_][A-Za-z0-9_]*)\b/g, (full, name) => (vars.has(name) ? vars.get(name) : full));
      }
      try {
        if (sqlStmt.includes('/*__GSET__*/')) {
          const res = await db.query(sqlStmt);
          if (res.rows && res.rows[0]) {
            for (const [col, val] of Object.entries(res.rows[0])) {
              vars.set(col, String(val));
            }
          }
        } else {
          await db.exec(sqlStmt);
        }
      } catch (e) {
        broke = k;
        err = e;
        try {
          await db.exec('rollback;');
        } catch (_) {
          /* the file's own transaction is gone; the next file starts its own */
        }
        break;
      }
    }
    if (broke < 0) {
      console.log(`PASS  ${file}  (${stmts.length} statements)`);
    } else {
      failed++;
      console.log(`FAIL  ${file}  (statement ${broke + 1}/${stmts.length})`);
      console.log(`      [${err.code}] ${(err.message || '').split('\n')[0]}`);
      if (err.where) console.log(`      where: ${String(err.where).split('\n').slice(0, 2).join(' | ')}`);
      if (err.hint) console.log(`      hint: ${err.hint}`);
      const s = stmts[broke];
      console.log(
        `      statement: ${JSON.stringify(
          s.split('\n').filter((l) => !l.trim().startsWith('--')).join(' ').slice(0, 240)
        )}`
      );
    }
  }
  if (failed) {
    console.error(`\n${failed} test file(s) failed.`);
    process.exitCode = 1;
  }
}

main();

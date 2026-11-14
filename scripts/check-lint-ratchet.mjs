#!/usr/bin/env node
// Lint ratchets for apps/web/src.
//
//   npm run lint:ratchet --workspace=apps/web                  check every ratchet (CI)
//   npm run lint:any --workspace=apps/web                      check one (also: lint:dialogs, lint:swallowed, lint:hook-deps)
//   npm run lint:ratchet:baseline --workspace=apps/web         rewrite baselines after fixing violations
//   ... -- --allow-increase                                    rewrite even if a count went UP (rare; say why in the PR)
//
// Each ratchet compares one ESLint rule's per-file violation count with a baseline file in apps/web.
// It fails when
//   * a file has MORE violations than its baseline (a file not in the baseline counts as 0), or
//   * a file has FEWER (the baseline is stale, so the improvement would not be locked in).
// ZERO_TOLERANCE rules have no baseline: any violation fails.
// ESLint runs once for all ratchets. Run from apps/web (the npm scripts do); ESLint and its
// config are resolved from there. Rules are configured in apps/web/eslint.config.js.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const RATCHETS = {
  any: {
    rule: '@typescript-eslint/no-explicit-any',
    baseline: 'eslint-any-baseline.json',
    label: '`any`',
    hint: 'Type the value instead (Tables<"x"> / TablesInsert<"x"> from @erp-platform/shared, or unknown plus a check).',
  },
  dialogs: {
    rule: 'no-alert',
    baseline: 'eslint-dialogs-baseline.json',
    label: 'alert()/confirm()/prompt() calls',
    hint: 'Use useToast() (showError/showSuccess) from src/lib/toastContext.tsx, and `if (!(await confirm(...)))` with useConfirm() from src/lib/confirmContext.tsx.',
  },
  swallowed: {
    rule: 'local/supabase-no-swallowed-error',
    baseline: 'eslint-swallowed-baseline.json',
    label: 'supabase calls that drop `error`',
    hint: 'Destructure { data, error } and surface a failed request with showError() -- see ProposalApprovals.tsx fetchData().',
  },
  'hook-deps': {
    rule: 'react-hooks/exhaustive-deps',
    baseline: 'eslint-hook-deps-baseline.json',
    label: 'missing hook dependencies',
    hint: 'Add the dependency, or restructure so the effect/callback does not close over stale state. Do not silence it with a disable comment.',
  },
};
// Any violation of these fails, with no baseline.
const ZERO_TOLERANCE = ['react-hooks/rules-of-hooks'];

const argv = process.argv.slice(2);
const flags = new Set(argv.filter((a) => a.startsWith('--')));
const names = argv.filter((a) => !a.startsWith('--'));
const update = flags.has('--update');
const allowIncrease = flags.has('--allow-increase');
for (const n of names) {
  if (!RATCHETS[n]) { console.error(`lint:ratchet  unknown ratchet "${n}". Known: ${Object.keys(RATCHETS).join(', ')}`); process.exit(2); }
}
const selected = names.length ? names : Object.keys(RATCHETS);

const require = createRequire(path.join(process.cwd(), 'package.json'));
const { ESLint } = require('eslint');
const eslint = new ESLint({ cwd: process.cwd() });
const results = await eslint.lintFiles(['src']);

const counts = {};   // rule -> file -> count
const lines = {};    // rule -> file -> [line numbers]
let fatal = 0;
for (const r of results) {
  const file = path.relative(process.cwd(), r.filePath).split(path.sep).join('/');
  for (const m of r.messages) {
    if (m.fatal) { fatal++; console.error(`lint:ratchet  parse error in ${file}:${m.line}: ${m.message}`); continue; }
    if (!m.ruleId) continue;
    ((counts[m.ruleId] ??= {})[file] = (counts[m.ruleId][file] ?? 0) + 1);
    (((lines[m.ruleId] ??= {})[file]) ??= []).push(m.line);
  }
}
if (fatal) { console.error(`lint:ratchet  ${fatal} file(s) could not be parsed, so the counts are unreliable.`); process.exit(2); }

const total = (o) => Object.values(o).reduce((a, b) => a + b, 0);
const sorted = (o) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => a.localeCompare(b)));
const show = (items, fmt, max = 15) => {
  for (const it of items.slice(0, max)) console.error(fmt(it));
  if (items.length > max) console.error(`  ... and ${items.length - max} more`);
};

let failed = false;

// Zero-tolerance rules (only checked on a full run, never when rewriting baselines).
if (!update && !names.length) {
  for (const rule of ZERO_TOLERANCE) {
    const cur = counts[rule] ?? {};
    if (total(cur)) {
      failed = true;
      console.error(`lint:ratchet  FAIL: ${rule} must have no violations:`);
      show(Object.keys(cur).sort(), (f) => `  ${f}, at line${lines[rule][f].length > 1 ? 's' : ''} ${lines[rule][f].join(', ')}`);
    }
  }
}

for (const name of selected) {
  const { rule, baseline: file, label, hint } = RATCHETS[name];
  const tag = `lint:${name}`;
  const current = counts[rule] ?? {};
  const hasBaseline = fs.existsSync(file);
  const baseline = hasBaseline ? JSON.parse(fs.readFileSync(file, 'utf8')).files : {};

  const all = [...new Set([...Object.keys(baseline), ...Object.keys(current)])].sort();
  const up = [], down = [];
  for (const f of all) {
    const now = current[f] ?? 0, was = baseline[f] ?? 0;
    if (now > was) up.push({ f, now, was });
    else if (now < was) down.push({ f, now, was });
  }

  if (update) {
    if (hasBaseline && up.length && !allowIncrease) {
      console.error(`${tag}  refusing to raise the baseline (use -- --allow-increase if that is really intended):`);
      show(up, ({ f, now, was }) => `  ${f}: ${was} -> ${now}`);
      failed = true;
      continue;
    }
    const out = {
      _comment: `Per-file counts of ${rule}. A ratchet: it may only go down. See scripts/check-lint-ratchet.mjs.`,
      total: total(current),
      files: sorted(current),
    };
    fs.writeFileSync(file, JSON.stringify(out, null, 2) + '\n');
    console.log(`${tag}  baseline written: ${out.total} ${label} in ${Object.keys(out.files).length} files.`);
    continue;
  }

  if (!hasBaseline) {
    console.error(`${tag}  FAIL: ${file} is missing. Create it once with: npm run lint:ratchet:baseline --workspace=apps/web`);
    failed = true;
    continue;
  }
  if (up.length) {
    failed = true;
    console.error(`${tag}  FAIL: more ${label} than the baseline allows:`);
    show(up, ({ f, now, was }) => `  ${f}: ${now} (baseline ${was}), at line${lines[rule][f].length > 1 ? 's' : ''} ${lines[rule][f].join(', ')}`);
    console.error(hint);
  } else if (down.length) {
    failed = true;
    console.error(`${tag}  FAIL: the baseline is stale. Fewer ${label} than recorded, so lock the improvement in:`);
    show(down, ({ f, now, was }) => `  ${f}: ${was} -> ${now}`);
    console.error(`Run: npm run lint:ratchet:baseline --workspace=apps/web   and commit ${file}`);
  } else {
    console.log(`${tag}  OK: ${total(current)} ${label} in ${Object.keys(current).length} files, none over the baseline.`);
  }
}
process.exit(failed ? 1 : 0);

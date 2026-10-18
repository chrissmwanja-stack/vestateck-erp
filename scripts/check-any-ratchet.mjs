#!/usr/bin/env node
// Ratchet for `@typescript-eslint/no-explicit-any` in apps/web/src.
//
//   npm run lint:any --workspace=apps/web                 check (CI)
//   npm run lint:any:baseline --workspace=apps/web        rewrite the baseline after removing `any`
//   ... -- --allow-increase                                rewrite even if a count went UP (rare; say why in the PR)
//
// Compares each file's count with apps/web/eslint-any-baseline.json. It fails when
//   * a file has MORE `any` than its baseline (a file not in the baseline counts as 0), or
//   * a file has FEWER (the baseline is stale, so the improvement would not be locked in).
// Run from apps/web (the npm scripts do); ESLint and its config are resolved from there.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const RULE = '@typescript-eslint/no-explicit-any';
const BASELINE = 'eslint-any-baseline.json';
const args = new Set(process.argv.slice(2));
const update = args.has('--update');
const allowIncrease = args.has('--allow-increase');

const require = createRequire(path.join(process.cwd(), 'package.json'));
const { ESLint } = require('eslint');

const eslint = new ESLint({ cwd: process.cwd() });
const results = await eslint.lintFiles(['src']);

const current = {};   // file -> count
const lines = {};     // file -> [line numbers]
let fatal = 0;
for (const r of results) {
  const file = path.relative(process.cwd(), r.filePath).split(path.sep).join('/');
  for (const m of r.messages) {
    if (m.fatal) { fatal++; console.error(`lint:any  parse error in ${file}:${m.line}: ${m.message}`); continue; }
    if (m.ruleId !== RULE) continue;
    current[file] = (current[file] ?? 0) + 1;
    (lines[file] ??= []).push(m.line);
  }
}
if (fatal) { console.error(`lint:any  ${fatal} file(s) could not be parsed, so the count is unreliable.`); process.exit(2); }

const total = (o) => Object.values(o).reduce((a, b) => a + b, 0);
const sorted = (o) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => a.localeCompare(b)));
const hasBaseline = fs.existsSync(BASELINE);
const baseline = hasBaseline ? JSON.parse(fs.readFileSync(BASELINE, 'utf8')).files : {};
const show = (items, fmt, max = 15) => {
  for (const it of items.slice(0, max)) console.error(fmt(it));
  if (items.length > max) console.error(`  ... and ${items.length - max} more`);
};

const files = [...new Set([...Object.keys(baseline), ...Object.keys(current)])].sort();
const up = [], down = [];
for (const f of files) {
  const now = current[f] ?? 0, was = baseline[f] ?? 0;
  if (now > was) up.push({ f, now, was });
  else if (now < was) down.push({ f, now, was });
}

if (update) {
  if (hasBaseline && up.length && !allowIncrease) {
    console.error('lint:any  refusing to raise the baseline (use -- --allow-increase if that is really intended):');
    show(up, ({ f, now, was }) => `  ${f}: ${was} -> ${now}`);
    process.exit(1);
  }
  const out = {
    _comment: 'Per-file counts of @typescript-eslint/no-explicit-any. A ratchet: it may only go down. See scripts/check-any-ratchet.mjs.',
    total: total(current),
    files: sorted(current),
  };
  fs.writeFileSync(BASELINE, JSON.stringify(out, null, 2) + '\n');
  console.log(`lint:any  baseline written: ${out.total} uses in ${Object.keys(out.files).length} files.`);
  process.exit(0);
}

if (!hasBaseline) {
  console.error(`lint:any  FAIL: ${BASELINE} is missing. Create it once with: npm run lint:any:baseline --workspace=apps/web`);
  process.exit(1);
}
if (up.length) {
  console.error('lint:any  FAIL: more `any` than the baseline allows:');
  show(up, ({ f, now, was }) => `  ${f}: ${now} (baseline ${was}), at line${lines[f].length > 1 ? 's' : ''} ${lines[f].join(', ')}`);
  console.error('Type the value instead (Tables<"x"> / TablesInsert<"x"> from @erp-platform/shared, or unknown plus a check).');
  process.exit(1);
}
if (down.length) {
  console.error('lint:any  FAIL: the baseline is stale. Fewer `any` than recorded, so lock the improvement in:');
  show(down, ({ f, now, was }) => `  ${f}: ${was} -> ${now}`);
  console.error('Run: npm run lint:any:baseline --workspace=apps/web   and commit eslint-any-baseline.json');
  process.exit(1);
}
console.log(`lint:any  OK: ${total(current)} \`any\` uses in ${Object.keys(current).length} files, none over the baseline.`);

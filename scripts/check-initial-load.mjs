#!/usr/bin/env node
// Guards the first-load bundle of apps/web.
//
// Walks the static import graph of everything index.html loads on first paint
// (the entry script plus its modulepreload links) and fails when:
//   1. a chunk that should only be fetched on demand is on that graph -- the
//      PDF/Excel/screenshot libraries (xlsx, pdf = jspdf, html2canvas) or recharts; or
//   2. the total size of the first-paint JS exceeds INITIAL_JS_BUDGET_BYTES.
//
// Why: Vite's own dynamic-import preload helper once ended up inside the jspdf
// manual chunk, which made the entry import all 374 kB of jsPDF on every page
// load without any source file asking for it. Nothing in the source diff shows
// that kind of regression, so it has to be checked on the built output.
//
// Usage: node scripts/check-initial-load.mjs [path/to/dist]   (run after the build)

import { readFileSync, existsSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';

const dist = resolve(process.argv[2] ?? 'apps/web/dist');
const FORBIDDEN = ['xlsx', 'pdf', 'html2canvas', 'recharts'];
// Initial JS was ~1.48 MB when this was written; the budget leaves ~15% headroom.
const INITIAL_JS_BUDGET_BYTES = 1_700_000;

if (!existsSync(join(dist, 'index.html'))) {
  console.error(`check-initial-load: ${dist}/index.html not found -- run the build first.`);
  process.exit(2);
}

const html = readFileSync(join(dist, 'index.html'), 'utf8');
const entryPoints = [
  ...html.matchAll(/<script[^>]*type="module"[^>]*src="\/(assets\/[^"]+\.js)"/g),
  ...html.matchAll(/<link[^>]*rel="modulepreload"[^>]*href="\/(assets\/[^"]+\.js)"/g),
].map((m) => m[1].replace(/^assets\//, ''));

if (entryPoints.length === 0) {
  console.error('check-initial-load: found no entry script in index.html (has the HTML format changed?).');
  process.exit(2);
}

// Static imports only: `from"./x.js"` and bare `import"./x.js"`. A dynamic
// `import("./x.js")` has a parenthesis and is deliberately not matched.
const STATIC_IMPORT = /(?:\bfrom|\bimport)\s*["']\.\/([A-Za-z0-9_.-]+\.js)["']/g;

const seen = new Map(); // chunk -> importer
const queue = entryPoints.map((c) => [c, '(index.html)']);
while (queue.length) {
  const [chunk, importer] = queue.shift();
  if (seen.has(chunk)) continue;
  seen.set(chunk, importer);
  const file = join(dist, 'assets', chunk);
  if (!existsSync(file)) continue;
  const code = readFileSync(file, 'utf8');
  for (const m of code.matchAll(STATIC_IMPORT)) queue.push([m[1], chunk]);
}

const nameOf = (chunk) => chunk.replace(/-[A-Za-z0-9_-]{8}\.js$/, '');
const problems = [];

for (const [chunk, importer] of seen) {
  if (FORBIDDEN.includes(nameOf(chunk))) {
    problems.push(
      `${chunk} is loaded on first paint (imported by ${importer}). It should only load on demand.`
    );
  }
}

let total = 0;
for (const chunk of seen.keys()) {
  const file = join(dist, 'assets', chunk);
  if (existsSync(file)) total += statSync(file).size;
}
const kb = (n) => `${(n / 1000).toFixed(0)} kB`;
console.log(`initial JS: ${kb(total)} across ${seen.size} chunks (${[...seen.keys()].map(nameOf).join(', ')})`);

if (total > INITIAL_JS_BUDGET_BYTES) {
  problems.push(
    `initial JS is ${kb(total)}, over the ${kb(INITIAL_JS_BUDGET_BYTES)} budget in scripts/check-initial-load.mjs. ` +
      'If the growth is intended, raise the budget in the same PR and say why.'
  );
}

if (problems.length) {
  console.error('\ncheck-initial-load FAILED:');
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log('check-initial-load OK: no on-demand chunks on the first-paint graph.');

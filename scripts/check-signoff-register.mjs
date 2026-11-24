#!/usr/bin/env node
// Validates docs/insurance-brokerage/signoff-register.json.
//
// WHAT THIS PROVES
//   - every A/B ref is unique and well-formed;
//   - every gate named is a real gate, and every blocking_gate is one of them;
//   - every setting an item depends on EXISTS in accounting_setting_definitions;
//   - the value the pack claims is APPROVED is one the setting actually allows;
//   - every evidence file the item cites exists in the repo.
//
// WHAT THIS DOES NOT PROVE
//   It cannot tell whether the accounting behaviour behind a setting is correct.
//   A setting can exist, allow the value, and still not do what the policy says.
//   That is what the evidence files and the human `reviewed_at` field are for, and
//   why "implemented" is a claim the reviewer signs, not something this script infers.
//   Do not let a green run of this replace a test that demonstrates the behaviour.
//
// Usage:
//   node scripts/check-signoff-register.mjs --db postgres://...     (CI: reads the real definitions)
//   node scripts/check-signoff-register.mjs --definitions <file>    (offline: a dumped snapshot)
//   node scripts/check-signoff-register.mjs                         (offline: the committed snapshot)

import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REGISTER = join(ROOT, 'docs/insurance-brokerage/signoff-register.json');
const SNAPSHOT = join(ROOT, 'docs/insurance-brokerage/setting-definitions.snapshot.json');

const argv = process.argv.slice(2);
const dbIdx = argv.indexOf('--db');
const defIdx = argv.indexOf('--definitions');

function fail(msg) {
  console.error(`check-signoff-register: ${msg}`);
  process.exitCode = 1;
}

function loadDefinitions() {
  if (dbIdx >= 0 && argv[dbIdx + 1]) {
    // Query the replayed stack, so validation is against what will actually ship.
    const sql = `select coalesce(json_agg(json_build_object(
        'key', key,
        'allowed_values', allowed_values,
        'default_value', default_value,
        'implemented_values', implemented_values,
        'requires_legal_review', requires_legal_review
      ) order by key), '[]'::json)::text
      from public.accounting_setting_definitions;`;
    const out = execFileSync('psql', [argv[dbIdx + 1], '-t', '-A', '-c', sql], { encoding: 'utf8' });
    console.log('definitions: read from the database (authoritative)');
    return JSON.parse(out.trim());
  }
  const file = defIdx >= 0 && argv[defIdx + 1] ? resolve(argv[defIdx + 1]) : SNAPSHOT;
  if (!existsSync(file)) {
    fail(`no definitions available: pass --db, --definitions, or commit ${SNAPSHOT}`);
    process.exit(1);
  }
  console.log(`definitions: read from ${file.replace(ROOT + '/', '')} (snapshot -- run with --db in CI)`);
  return JSON.parse(readFileSync(file, 'utf8'));
}

const register = JSON.parse(readFileSync(REGISTER, 'utf8'));
const defs = new Map(loadDefinitions().map((d) => [d.key, d]));

const gates = new Set(register.gates);
if (!gates.size) fail('register.gates is empty');

const seen = new Set();
let settingCount = 0;
let evidenceCount = 0;

for (const section of ['items', 'unbuilt']) {
  const list = register[section] ?? [];
  if (!list.length) fail(`register.${section} is empty`);

  for (const row of list) {
    const where = `${section === 'items' ? 'A' : 'B'} item ${row.ref ?? '(no ref)'}`;

    // --- ref ---
    if (!row.ref) { fail(`${where}: missing ref`); continue; }
    const wantPrefix = section === 'items' ? /^A\d+$/ : /^B\d+$/;
    if (!wantPrefix.test(row.ref)) fail(`${where}: ref must match ${wantPrefix}`);
    if (seen.has(row.ref)) fail(`${where}: duplicate ref`);
    seen.add(row.ref);

    // --- gates ---
    if (section === 'items') {
      if (!gates.has(row.blocking_gate)) {
        fail(`${where}: blocking_gate "${row.blocking_gate}" is not one of ${[...gates].join(', ')}`);
      }
      for (const who of row.approver ?? []) {
        if (!['accountant', 'legal', 'tax'].includes(who)) fail(`${where}: unknown approver "${who}"`);
      }
      if (!row.decision || row.decision.length < 40) {
        fail(`${where}: decision statement is missing or too short to be a policy statement`);
      }
      if (!(row.code_state in { built: 1, partial: 1, not_built: 1 })) {
        fail(`${where}: code_state must be built | partial | not_built`);
      }
    } else {
      if (!gates.has(row.blocks)) fail(`${where}: blocks "${row.blocks}" is not one of ${[...gates].join(', ')}`);
      if (!row.acceptance) fail(`${where}: no acceptance criteria`);
    }

    // --- settings: exists AND allows the approved value ---
    for (const s of row.settings ?? []) {
      settingCount++;
      const def = defs.get(s.key);
      if (!def) {
        fail(`${where}: setting "${s.key}" does not exist in accounting_setting_definitions`);
        continue;
      }
      const allowed = def.allowed_values ?? [];
      // A policy may select a value the schema does not yet offer (e.g. a mode that
      // is approved but not built). That is allowed only when implemented is false,
      // so the register cannot claim a value the database rejects as implemented.
      if (!allowed.includes(s.selected_value) && s.implemented) {
        fail(
          `${where}: "${s.key}" is marked implemented but "${s.selected_value}" is not an allowed value ` +
          `(allowed: ${allowed.join(', ')})`
        );
      }
      if (!allowed.includes(s.selected_value) && !s.implemented) {
        console.log(
          `  note  ${where}: "${s.key}" does not yet allow "${s.selected_value}" -- consistent with implemented:false`
        );
      }
      if (s.implemented && def.implemented_values && !def.implemented_values.includes(s.selected_value)) {
        fail(
          `${where}: "${s.key}" is marked implemented, but the database's implemented_values ` +
          `(${(def.implemented_values ?? []).join(', ')}) excludes "${s.selected_value}"`
        );
      }
    }

    // --- evidence ---
    for (const e of row.evidence ?? []) {
      evidenceCount++;
      if (!existsSync(join(ROOT, e))) fail(`${where}: evidence file not found: ${e}`);
    }
  }
}

<<<<<<< ours
console.log(
  `\n${register.items.length} policy items, ${register.unbuilt.length} unbuilt items, ` +
  `${settingCount} setting assertions, ${evidenceCount} evidence files checked.`
=======
// ---------------------------------------------------------------------------
// Acceptance evidence
// ---------------------------------------------------------------------------
// Added because the register could otherwise be satisfied by building things. The
// distinction that matters to a reviewer is not "is it built" but "how much has been
// demonstrated": executing a guard is not executing a workflow, and neither is UAT.
// These rules make an upgrade of that claim a visible edit rather than a silent one.
const ae = register.acceptance_evidence;
if (!ae) {
  fail('register.acceptance_evidence is missing -- every pack must state how far its claims are demonstrated');
} else {
  const levels = new Set(Object.keys(ae.levels ?? {}));
  if (!levels.size) fail('acceptance_evidence.levels is empty');
  const aeSeen = new Set();
  let aeEvidence = 0;

  for (const row of ae.items ?? []) {
    const where = `acceptance evidence ${row.ref ?? '(no ref)'}`;
    if (!row.ref) { fail(`${where}: missing ref`); continue; }
    if (!/^AE\d+$/.test(row.ref)) fail(`${where}: ref must match /^AE\\d+$/`);
    if (aeSeen.has(row.ref)) fail(`${where}: duplicate ref`);
    aeSeen.add(row.ref);
    if (seen.has(row.ref)) fail(`${where}: ref collides with an A/B item ref`);
    if (aeSeen.size && !levels.has(row.classification)) {
      fail(`${where}: classification "${row.classification}" is not one of ${[...levels].join(', ')}`);
    }
    if (!gates.has(row.blocking_gate) && row.blocking_gate !== null) {
      fail(`${where}: blocking_gate "${row.blocking_gate}" is not one of ${[...gates].join(', ')} (or null)`);
    }

    // A deliberate behaviour change is only approved if it says what it blocks, when, and
    // how a mistaken action is corrected. A change that cannot answer those is not specified.
    if (row.classification === 'deliberate_behaviour_change') {
      const spec = row.behaviour_specification;
      if (!spec) { fail(`${where}: a deliberate behaviour change needs a behaviour_specification`); continue; }
      for (const field of ['what_changed', 'which_actions_become_unavailable', 'trigger_condition',
                           'observable_effect', 'harm_prevented', 'authorised_correction_route']) {
        if (!spec[field] || String(spec[field]).length < 10) {
          fail(`${where}: behaviour_specification.${field} is missing or too short to be a specification`);
        }
      }
      if (row.approved !== true) fail(`${where}: the reviewer approved this change; approved must be true`);
      if (!row.approved_by) fail(`${where}: approved_by is required when approved is true`);
    }

    // Guard-level evidence must not quietly become acceptance. If a row claims this level it
    // must carry something it was run against, and must state what it does NOT establish.
    if (row.classification === 'guard_level_verification') {
      if (!(row.evidence_present ?? []).length) {
        fail(`${where}: guard-level verification with no evidence_present`);
      }
      if (!(row.evidence_explicitly_not_established ?? []).length) {
        fail(`${where}: guard-level verification must list what it does not establish`);
      }
    }

    // Anything not yet approved must not carry evidence, or the next reader will read the
    // evidence as acceptance.
    if (row.approved === false && (row.evidence_present ?? []).length) {
      fail(`${where}: approved is false but evidence_present is not empty -- move it to the row that owns it`);
    }

    for (const e of row.evidence_present ?? []) {
      if (e.includes('/') && !e.includes(' ')) { evidenceCount++; aeEvidence++; }
    }
  }
}

console.log(
  `\n${register.items.length} policy items, ${register.unbuilt.length} unbuilt items, ` +
  `${settingCount} setting assertions, ${evidenceCount} evidence files checked, ` +
  `${ae?.items?.length ?? 0} acceptance-evidence rows.`
>>>>>>> theirs
);

if (process.exitCode) {
  console.error('\nFAILED. Fix the rows above before this pack is signed.');
} else {
  console.log(
    'Register is internally consistent.\n' +
    'This does NOT prove the accounting behaviour is correct -- see the header. ' +
    'Behaviour is evidenced by the files listed above and signed off by reviewed_at.'
  );
}

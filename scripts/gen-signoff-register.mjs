#!/usr/bin/env node
// Generates the sign-off register tables in docs/insurance-brokerage/ACCOUNTANT_PACK.md
// from docs/insurance-brokerage/signoff-register.json, between the marker comments
//   <!-- BEGIN GENERATED: SIGN-OFF REGISTER -->  ...  <!-- END GENERATED: SIGN-OFF REGISTER -->
//
// Never edit the generated block by hand: edit the JSON and re-run this.
// CI runs `--check` so a stale table fails the build.

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REGISTER = join(ROOT, 'docs/insurance-brokerage/signoff-register.json');
const PACK = join(ROOT, 'docs/insurance-brokerage/ACCOUNTANT_PACK.md');

const BEGIN = '<!-- BEGIN GENERATED: SIGN-OFF REGISTER -->';
const END = '<!-- END GENERATED: SIGN-OFF REGISTER -->';

const register = JSON.parse(readFileSync(REGISTER, 'utf8'));
const when = register.generated_at ?? 'generated from signoff-register.json';

const stateLabel = { built: 'Built', partial: 'Partly built', not_built: 'Not built' };
const gateLabel = {
  policy_approval: 'policy approval',
  uat_acceptance: 'UAT acceptance',
  production_golive: 'production go-live',
};

function settingsCell(row) {
  if (!row.settings?.length) return '—';
  return row.settings
    .map((s) => {
      const mark = s.implemented ? '' : ' *(not yet implemented)*';
      return `\`${s.key}\` = **${s.selected_value}**${mark}`;
    })
    .join('<br>');
}

function evidenceCell(row) {
  if (!row.evidence?.length) return '—';
  return row.evidence.map((e) => `\`${e.replace('supabase/tests/', '')}\``).join('<br>');
}

const aRows = register.items
  .map(
    (r) =>
      `| **${r.ref}** | ${r.area} | ${r.approver.join(' + ')} | ${stateLabel[r.code_state]} | ${settingsCell(
        r
      )} | ${gateLabel[r.blocking_gate]} | ${evidenceCell(r)} |`
  )
  .join('\n');

const bRows = register.unbuilt
  .map(
    (r) =>
      `| **${r.ref}** | ${r.feature} | ${r.status === 'not_built' ? 'Not built' : r.status} | ${r.depends_on.join(
        ', '
      )} | ${gateLabel[r.blocks]} | ${r.acceptance} |`
  )
  .join('\n');

<<<<<<< ours
<<<<<<< ours
=======
=======
>>>>>>> theirs
const classLabel = {
  deliberate_behaviour_change: 'Deliberate behaviour change',
  guard_level_verification: 'Guard-level verification',
  end_to_end_not_demonstrated: 'Not yet demonstrated',
  uat_pending: 'Pending',
};

const ae = register.acceptance_evidence ?? { items: [] };
const aeRows = (ae.items ?? [])
  .map((r) => {
    const state = r.approved
      ? `Approved${r.approved_by ? ` (${r.approved_by})` : ''}`
      : 'Not yet approved';
    return `| **${r.ref}** | ${r.subject} | ${classLabel[r.classification] ?? r.classification} | ${state} | ${r.required_evidence} |`;
  })
  .join('\n');

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
const block = `${BEGIN}
<!-- Do not edit by hand. Edit docs/insurance-brokerage/signoff-register.json and run
     node scripts/gen-signoff-register.mjs -->

### 16.1 Accounting policy items (A-register)

Each item is the accounting treatment the software is expected to implement. \`reviewed_at\`
is filled only when the appointed reviewer has signed that item in section 18.

| Ref | Decision area | Approver | Code | Selected settings | Required before | Evidence |
|---|---|---|---|---|---|---|
${aRows}

### 16.2 Committed but not built (B-register)

These are controls and features the policy assumes. **They are not built.** The reviewer is
asked to approve the *policy* in §16.1 while acknowledging these as committed work with the
gate shown. An item blocking "production go-live" must be complete before live posting; an
item blocking "UAT acceptance" must be complete before the business signs UAT.

| Ref | Feature | Status | Depends on | Blocks | Acceptance criteria |
|---|---|---|---|---|---|
${bRows}

<<<<<<< ours
<<<<<<< ours
=======
=======
>>>>>>> theirs
### 16.3 How far each claim has been demonstrated

**Built and demonstrated are different things.** A control can be built, parse-checked, and
still never have refused anything; a guard can be shown to execute without the document
workflow around it working. This table states which is which, because a reviewer deciding
whether the protection is real is asking this question, not the one in §16.1.

Kept in \`signoff-register.json\` under \`acceptance_evidence\` and validated: a row claiming
guard-level evidence must list what it does **not** establish, a deliberate behaviour change
must state what it blocks, under what condition, and how a mistake is corrected, and a row
that is not approved may not carry evidence.

| Ref | Subject | Classification | State | Required evidence |
|---|---|---|---|---|
${aeRows}

<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
${END}`;

const source = readFileSync(PACK, 'utf8');
const start = source.indexOf(BEGIN);
const end = source.indexOf(END);

if (start < 0 || end < 0) {
  console.error(`gen-signoff-register: markers not found in ${PACK.replace(ROOT + '/', '')}`);
  process.exit(1);
}

const updated = source.slice(0, start) + block + source.slice(end + END.length);
const checkOnly = process.argv.includes('--check');

if (checkOnly) {
  if (updated !== source) {
    console.error(
      'gen-signoff-register: the register tables in ACCOUNTANT_PACK.md are stale.\n' +
      'Run: node scripts/gen-signoff-register.mjs'
    );
    process.exit(1);
  }
  console.log('gen-signoff-register: tables are up to date.');
} else {
  writeFileSync(PACK, updated, 'utf8');
  console.log(`gen-signoff-register: wrote ${register.items.length} A-items and ${register.unbuilt.length} B-items into ACCOUNTANT_PACK.md (${when}).`);
}

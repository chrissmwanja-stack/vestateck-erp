import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

// Source-shape guard, not a behavioural test. The invite edge functions need
// `supabase functions serve` plus an email sink, which CI does not run (see
// e2e/company-admin-members-invitations.spec.ts), so nothing else would catch
// them drifting back to the "admin of any module" model that
// 20261002054037_invitations_company_admin_only removed from the database.
//
// If this fails, member-invite authorization in the function no longer matches
// invitations_select / invitations_insert / revoke_invitation(): it must key on
// app_users.is_company_admin and must not query staff_roles.

const FUNCTIONS_DIR = resolve(__dirname, '../../../../../supabase/functions');

describe.each(['invite-user', 'resend-invite'])('%s edge function authorization', (fn) => {
  const source = readFileSync(resolve(FUNCTIONS_DIR, fn, 'index.ts'), 'utf8');
  // Strip // line comments so the history notes in the file do not count.
  const code = source
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');

  it('keys member-invite authorization on is_company_admin', () => {
    expect(code).toMatch(/is_company_admin/);
  });

  it("does not query staff_roles to decide who may manage invitations", () => {
    expect(code).not.toMatch(/\.from\(\s*['"]staff_roles['"]\s*\)/);
  });
});

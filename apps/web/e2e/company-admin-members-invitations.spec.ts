import { test, expect, Page } from '@playwright/test';
import { loginAs, logout } from './utils/auth';
import {
  captureRestSession,
  myTenantId,
  restInsert,
  restSelect,
  type RestSession,
  wasRefusedOrNoOp,
} from './utils/supabaseRest';

/**
 * Company Admin owns team members and invitations.
 *
 * Completes the chain started in company-admin-org-setup.spec.ts:
 *   Company Admin -> departments -> organizations -> MEMBERS -> INVITATIONS
 *
 * SQL side: supabase/tests/test_invitations_authorization.sql (policies and
 * revoke_invitation) and security_authorization.sql (set_member_access).
 * This spec covers the real screens and the real HTTP path a browser, or a
 * hostile client holding a user's JWT, takes.
 *
 *   1. Company admin edits an existing member's module access through the
 *      UI; the change shows in the table and is restored afterwards.
 *   2. Non-admins (hr = module admin but NOT company admin, finance) are
 *      stopped at the route guard for both screens.
 *   3. Non-admins are refused by the DATABASE: get_tenant_team_members
 *      returns nothing, set_member_access raises (including on themselves),
 *      invitations cannot be read, inserted or revoked, and the invitation
 *      is left pending.
 *   4. Company admin: invite form validation, then a pending invitation is
 *      listed and revoked through the UI.
 *
 * NOT covered here: sending an invite through the invite-user edge function,
 * resending one through resend-invite (it needs `supabase functions serve`
 * plus an email sink, neither of which the CI stack runs) and accepting one
 * (accept-invite). Those need their own harness. Until then, the shape of
 * invite-user's and resend-invite's authorization (is_company_admin, no
 * staff_roles lookup) is pinned by
 * src/features/team/inviteEdgeAuth.test.ts.
 *
 * Personas: company.admin@test.local (company admin, no module role),
 * hr@test.local (hr module admin, not a company admin), finance@test.local
 * (finance team, not a company admin), machine.ops@test.local (the member
 * whose access is edited and then restored; no other spec uses it).
 *
 * Reruns: invitations have no DELETE policy by design, so the revoked
 * invitation rows from step 4 remain (timestamped, terminal state). Member
 * access is restored in a finally block.
 */

const MEMBERS_URL = '/company-admin/users/members';
const INVITE_URL = '/company-admin/users/invite';
const MEMBER_EMAIL = 'machine.ops@test.local';
const ADDED_MODULE_LABEL = 'Sustainability';

interface Grant {
  module: string;
  role: string;
}
interface TeamMemberRow {
  user_id: string;
  email: string;
  modules: Grant[];
  finance_role: string | null;
}

function rpc(page: Page, s: RestSession, name: string, body: Record<string, unknown> = {}) {
  return page.request.post(`${s.restUrl}/rpc/${name}`, {
    headers: {
      apikey: s.apikey,
      Authorization: `Bearer ${s.accessToken}`,
      'Content-Type': 'application/json',
    },
    data: body,
  });
}

async function resetSession(page: Page) {
  await page.context().clearCookies();
  await page.evaluate(() => localStorage.clear());
}

test.describe('Company Admin: members and invitations', () => {
  test('company admin edits a member\'s module access through the UI', async ({ page }) => {
    await loginAs(page, 'companyAdmin');
    const admin = await captureRestSession(page);

    const before = (await (await rpc(page, admin, 'get_tenant_team_members')).json()) as TeamMemberRow[];
    const target = before.find((m) => m.email === MEMBER_EMAIL);
    expect(target, `${MEMBER_EMAIL} must exist in the seeded tenant`).toBeTruthy();
    const originalModules = target!.modules.map(({ module, role }) => ({ module, role }));
    const originalFinance = target!.finance_role ?? '';
    expect(target!.modules.some((g) => g.module === 'sustainability')).toBeFalsy();

    try {
      await page.goto(MEMBERS_URL);
      await expect(page.getByRole('heading', { name: 'Team members' })).toBeVisible();

      const row = page.getByRole('row').filter({ has: page.getByRole('cell', { name: MEMBER_EMAIL, exact: true }) });
      // Explicit short timeouts: without them a missing element waits for the
      // whole 60s test budget, the finally block's restore call then dies with
      // "Test timeout exceeded", and the real cause is hidden.
      await expect(row, `${MEMBER_EMAIL} must be listed on the Team members screen`).toBeVisible({ timeout: 15_000 });
      await row.getByRole('button', { name: 'Edit access' }).click({ timeout: 10_000 });

      const dialog = page.getByRole('dialog');
      await expect(dialog.getByText(`Edit access — ${MEMBER_EMAIL}`)).toBeVisible({ timeout: 10_000 });
      // The checkbox list is built from the platform_modules registry
      // (tenant_entitled rows only), so a missing box means the registry did
      // not load or the module is not in it -- say so instead of hanging.
      const moduleBox = dialog.getByRole('checkbox', { name: ADDED_MODULE_LABEL });
      await expect(
        moduleBox,
        `"${ADDED_MODULE_LABEL}" checkbox missing from the Edit access dialog (platform_modules registry not loaded, or migrations not applied to this stack?)`,
      ).toBeVisible({ timeout: 10_000 });
      await moduleBox.check({ timeout: 10_000 });
      await dialog.getByRole('button', { name: 'Save changes' }).click({ timeout: 10_000 });

      await expect(page.getByText(`Updated access for ${MEMBER_EMAIL}.`)).toBeVisible({ timeout: 15_000 });
      await expect(row.getByText(`${ADDED_MODULE_LABEL} (member)`)).toBeVisible({ timeout: 15_000 });
    } finally {
      const restore = await rpc(page, admin, 'set_member_access', {
        p_user_id: target!.user_id,
        p_modules: originalModules,
        p_finance_role: originalFinance,
      });
      // Include the database's own message: a bare "false" hides why the RPC
      // refused, and this finally block would otherwise replace (mask) any
      // error thrown by the try body above.
      const restoreBody = restore.ok() ? '' : await restore.text();
      expect(
        restore.ok(),
        `restoring the member's original access must succeed (HTTP ${restore.status()}: ${restoreBody})`,
      ).toBeTruthy();
    }
  });

  for (const persona of ['hr', 'finance'] as const) {
    test(`${persona} is stopped at the members and invite route guards`, async ({ page }) => {
      await loginAs(page, persona);

      for (const url of [MEMBERS_URL, INVITE_URL]) {
        await page.goto(url);
        await expect(page.getByText('Company admin only')).toBeVisible({ timeout: 15_000 });
        await expect(page.getByRole('button', { name: 'Send invite' })).toHaveCount(0);
        await expect(page.getByRole('button', { name: 'Edit access' })).toHaveCount(0);
      }
    });
  }

  for (const persona of ['hr', 'finance'] as const) {
    test(`the database refuses team-access and invitation writes from ${persona}`, async ({ page }) => {
      const email = `e2e-guarded-${persona}-${Date.now()}@example.test`;

      // Fixture: a pending invitation created by the company admin.
      await loginAs(page, 'companyAdmin');
      const admin = await captureRestSession(page);
      const tenantId = await myTenantId(page, admin);
      const created = await restInsert(page, admin, 'invitations', {
        tenant_id: tenantId,
        email,
        invited_by: admin.userId,
        role_bundle: 'member',
        modules_and_roles: [{ module: 'hr', role: 'member' }],
      });
      expect(created.ok(), 'company admin must be able to create an invitation row').toBeTruthy();
      const [invitation] = (await created.json()) as { id: string }[];
      await logout(page);

      try {
        await loginAs(page, persona);
        const user = await captureRestSession(page);

        await test.step('get_tenant_team_members returns nothing', async () => {
          const res = await rpc(page, user, 'get_tenant_team_members');
          const rows = res.ok() ? ((await res.json()) as unknown[]) : [];
          expect(rows).toHaveLength(0);
        });

        await test.step('set_member_access is refused, even on themselves', async () => {
          const res = await rpc(page, user, 'set_member_access', {
            p_user_id: user.userId,
            p_modules: [{ module: 'procurement', role: 'admin' }],
            p_finance_role: 'finance',
          });
          expect(res.ok(), `set_member_access should be refused, got ${res.status()}`).toBeFalsy();
        });

        await test.step('cannot READ invitations', async () => {
          const rows = await restSelect(page, user, `invitations?id=eq.${invitation.id}&select=id`);
          expect(rows).toHaveLength(0);
        });

        await test.step('cannot INSERT an invitation granting modules and finance', async () => {
          const res = await restInsert(page, user, 'invitations', {
            tenant_id: tenantId,
            email: `e2e-escalate-${persona}-${Date.now()}@example.test`,
            invited_by: user.userId,
            role_bundle: 'member',
            modules_and_roles: [{ module: 'procurement', role: 'admin' }],
            finance_role: 'finance',
          });
          expect(res.ok(), `INSERT should be refused, got ${res.status()}`).toBeFalsy();
        });

        await test.step('cannot REVOKE an invitation', async () => {
          const res = await rpc(page, user, 'revoke_invitation', { p_invitation_id: invitation.id });
          expect(res.ok(), `revoke_invitation should be refused, got ${res.status()}`).toBeFalsy();
        });

        await test.step('cannot UPDATE an invitation directly', async () => {
          const res = await page.request.patch(`${user.restUrl}/invitations?id=eq.${invitation.id}`, {
            headers: {
              apikey: user.apikey,
              Authorization: `Bearer ${user.accessToken}`,
              'Content-Type': 'application/json',
              Prefer: 'return=representation',
            },
            data: { status: 'revoked' },
          });
          expect(await wasRefusedOrNoOp(res), 'UPDATE must be refused or change no rows').toBeTruthy();
        });
      } finally {
        await resetSession(page);
        await loginAs(page, 'companyAdmin');
        const check = await captureRestSession(page);
        const rows = (await restSelect(page, check, `invitations?id=eq.${invitation.id}&select=status`)) as {
          status: string;
        }[];
        // Whatever happened above, the fixture must still be pending.
        expect(rows).toEqual([{ status: 'pending' }]);
      }
    });
  }

  test('company admin: invite form validation, then a pending invitation is listed and revoked', async ({ page }) => {
    const email = `e2e-invitee-${Date.now()}@example.test`;

    await loginAs(page, 'companyAdmin');
    const admin = await captureRestSession(page);
    const tenantId = await myTenantId(page, admin);

    await test.step('fixture: pending invitation, created through the API as the company admin', async () => {
      const res = await restInsert(page, admin, 'invitations', {
        tenant_id: tenantId,
        email,
        invited_by: admin.userId,
        role_bundle: 'member',
        modules_and_roles: [{ module: 'hr', role: 'member' }],
      });
      expect(res.ok(), 'company admin must be able to create an invitation row').toBeTruthy();
    });

    await page.goto(INVITE_URL);
    await expect(page.getByRole('heading', { name: 'Invite a teammate' })).toBeVisible();

    await test.step('form validation (no network call is made)', async () => {
      await page.getByRole('button', { name: 'Send invite' }).click();
      await expect(page.getByText('Email is required.')).toBeVisible();

      await page.getByLabel('Email').fill(`e2e-novalue-${Date.now()}@example.test`);
      await page.getByRole('button', { name: 'Send invite' }).click();
      await expect(page.getByText('Select at least one module, or grant finance access.')).toBeVisible();
    });

    const row = page.getByRole('row').filter({ has: page.getByRole('cell', { name: email, exact: true }) });

    await test.step('the pending invitation is listed (proves SELECT works without a staff_roles row)', async () => {
      await expect(row).toBeVisible({ timeout: 15_000 });
      await expect(row.getByText('pending')).toBeVisible();
      await expect(row.getByRole('button', { name: 'Revoke' })).toBeVisible();
    });

    await test.step('revoke', async () => {
      await row.getByRole('button', { name: 'Revoke' }).click();
      await page.getByRole('dialog').getByRole('button', { name: 'Revoke invite' }).click();
      await expect(page.getByText(`Invite for ${email} revoked.`)).toBeVisible({ timeout: 15_000 });
      await expect(row.getByText('revoked')).toBeVisible({ timeout: 15_000 });
      await expect(row.getByRole('button', { name: 'Revoke' })).toHaveCount(0);
    });
  });
});
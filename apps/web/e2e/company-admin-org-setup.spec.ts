import { test, expect } from '@playwright/test';
import { loginAs, logout } from './utils/auth';
import {
  captureRestSession,
  myTenantId,
  restDelete,
  restInsert,
  restSelect,
  restUpdate,
  wasRefusedOrNoOp,
} from './utils/supabaseRest';

/**
 * Company Admin owns departments and organizations
 * (migration 20261001120000_company_admin_owns_departments_organizations).
 *
 * The SQL side is covered by section H of supabase/tests/security_authorization.sql.
 * This spec covers what that cannot: the real screens, and the real HTTP
 * path a browser (or a hostile client holding a user's JWT) takes.
 *
 *   1. Company admin: create / rename / delete a department through the UI.
 *   2. Company admin: create / edit an organization through the UI.
 *      (OrganizationsAdmin has no Delete button; cleanup uses the API, which
 *      also proves DELETE is allowed for the company admin.)
 *   3. Non-admins (HR manager, finance officer) are stopped at the route
 *      guard and see no management controls.
 *   4. Non-admins are refused by the DATABASE, not just the UI: direct
 *      INSERT / UPDATE / DELETE against departments and organizations with
 *      their own JWT must be rejected or change nothing. Finance keeps READ
 *      access to organizations.
 *
 * Personas: company.admin@test.local (seed.sql section 5, company admin with
 * no module role and no finance row), hr@test.local (HR manager, not a
 * company admin), finance@test.local (finance team, not a company admin).
 *
 * Reruns: every record uses a timestamped marker and is removed at the end
 * (best effort, even when an assertion fails).
 *
 * Not covered here (SQL tests cover them): cross-tenant access, platform
 * admin outside View-as, impersonation sessions.
 */

const DEPARTMENTS_URL = '/company-admin/organization/departments';
const ORGANIZATIONS_URL = '/company-admin/organization/organizations';

test.describe('Company Admin: departments and organizations', () => {
  test('company admin can create, rename and delete a department', async ({ page }) => {
    const name = `E2E Dept ${Date.now()}`;
    const renamed = `${name} renamed`;

    await loginAs(page, 'companyAdmin');
    await page.goto(DEPARTMENTS_URL);
    await expect(page.getByRole('heading', { name: 'Departments' })).toBeVisible();

    await test.step('create', async () => {
      await page.getByRole('button', { name: 'New Department' }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByLabel('Name').fill(name);
      await dialog.getByRole('button', { name: 'Save' }).click();
      await expect(page.getByRole('cell', { name, exact: true })).toBeVisible({ timeout: 15_000 });
    });

    await test.step('rename', async () => {
      const row = page.getByRole('row').filter({ has: page.getByRole('cell', { name, exact: true }) });
      await row.getByRole('button', { name: 'Edit' }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByLabel('Name').fill(renamed);
      await dialog.getByRole('button', { name: 'Save' }).click();
      await expect(page.getByRole('cell', { name: renamed, exact: true })).toBeVisible({ timeout: 15_000 });
      await expect(page.getByRole('cell', { name, exact: true })).toHaveCount(0);
    });

    await test.step('delete', async () => {
      const row = page.getByRole('row').filter({ has: page.getByRole('cell', { name: renamed, exact: true }) });
      await row.getByRole('button', { name: 'Delete' }).click();
      await page.getByRole('dialog').getByRole('button', { name: 'Delete' }).click();
      await expect(page.getByRole('cell', { name: renamed, exact: true })).toHaveCount(0, { timeout: 15_000 });
    });
  });

  test('company admin can create and edit an organization', async ({ page }) => {
    const code = `E2E${Date.now()}`;
    const site = 'E2E Site';
    const renamedSite = 'E2E Site renamed';

    await loginAs(page, 'companyAdmin');
    const rest = await captureRestSession(page);

    try {
      await page.goto(ORGANIZATIONS_URL);
      await expect(page.getByRole('heading', { name: 'Organizations' })).toBeVisible();

      await test.step('create', async () => {
        await page.getByRole('button', { name: 'New Organization' }).click();
        const dialog = page.getByRole('dialog');
        await dialog.getByLabel('Company Code').fill(code);
        await dialog.getByLabel('Site Name').fill(site);
        await dialog.getByRole('button', { name: 'Save' }).click();
        await expect(page.getByRole('cell', { name: code, exact: true })).toBeVisible({ timeout: 15_000 });
      });

      await test.step('edit', async () => {
        const row = page.getByRole('row').filter({ has: page.getByRole('cell', { name: code, exact: true }) });
        await row.getByRole('button', { name: 'Edit' }).click();
        const dialog = page.getByRole('dialog');
        await dialog.getByLabel('Site Name').fill(renamedSite);
        await dialog.getByRole('button', { name: 'Save' }).click();
        await expect(page.getByRole('cell', { name: renamedSite, exact: true })).toBeVisible({ timeout: 15_000 });
      });
    } finally {
      // No Delete button in the UI. Remove via the API, which is also the
      // check that the company admin may DELETE organizations.
      const res = await restDelete(page, rest, 'organizations', `company_code=eq.${code}`);
      expect(res.ok(), 'company admin must be able to delete an organization').toBeTruthy();
    }
  });

  for (const persona of ['hr', 'finance'] as const) {
    test(`${persona} is stopped at the Company Administration route guard`, async ({ page }) => {
      await loginAs(page, persona);

      for (const url of [DEPARTMENTS_URL, ORGANIZATIONS_URL]) {
        await page.goto(url);
        await expect(page.getByText('Company admin only')).toBeVisible({ timeout: 15_000 });
        await expect(page.getByRole('button', { name: 'New Department' })).toHaveCount(0);
        await expect(page.getByRole('button', { name: 'New Organization' })).toHaveCount(0);
      }
    });
  }

  test('the database refuses department writes from a non-admin (HR manager)', async ({ page }) => {
    const name = `E2E Guarded Dept ${Date.now()}`;

    // Fixture: a department created by the company admin.
    await loginAs(page, 'companyAdmin');
    const admin = await captureRestSession(page);
    const tenantId = await myTenantId(page, admin);
    const created = await restInsert(page, admin, 'departments', { tenant_id: tenantId, name });
    expect(created.ok(), 'company admin must be able to create the fixture department').toBeTruthy();
    const [dept] = (await created.json()) as { id: string }[];
    await logout(page);

    try {
      await loginAs(page, 'hr');
      const hr = await captureRestSession(page);

      await test.step('can still READ the list', async () => {
        const rows = await restSelect(page, hr, `departments?id=eq.${dept.id}&select=id,name`);
        expect(rows).toHaveLength(1);
      });

      await test.step('cannot INSERT', async () => {
        const res = await restInsert(page, hr, 'departments', { tenant_id: tenantId, name: `${name} intruder` });
        expect(res.ok(), `INSERT should be refused, got ${res.status()}`).toBeFalsy();
      });

      await test.step('cannot UPDATE', async () => {
        const res = await restUpdate(page, hr, 'departments', `id=eq.${dept.id}`, { name: `${name} hacked` });
        expect(await wasRefusedOrNoOp(res), 'UPDATE must be refused or change no rows').toBeTruthy();
      });

      await test.step('cannot DELETE', async () => {
        const res = await restDelete(page, hr, 'departments', `id=eq.${dept.id}`);
        expect(await wasRefusedOrNoOp(res), 'DELETE must be refused or remove no rows').toBeTruthy();
      });

      await test.step('the department is unchanged', async () => {
        const rows = (await restSelect(page, hr, `departments?id=eq.${dept.id}&select=name`)) as { name: string }[];
        expect(rows).toEqual([{ name }]);
      });
    } finally {
      await page.context().clearCookies();
      await page.evaluate(() => localStorage.clear());
      await loginAs(page, 'companyAdmin');
      const cleanup = await captureRestSession(page);
      await restDelete(page, cleanup, 'departments', `name=like.${encodeURIComponent(name)}*`);
    }
  });

  test('the database refuses organization writes from the finance team, which keeps read access', async ({ page }) => {
    const code = `E2EG${Date.now()}`;

    await loginAs(page, 'companyAdmin');
    const admin = await captureRestSession(page);
    const tenantId = await myTenantId(page, admin);
    const created = await restInsert(page, admin, 'organizations', {
      tenant_id: tenantId,
      company_code: code,
      site_name: 'Guarded Site',
    });
    expect(created.ok(), 'company admin must be able to create the fixture organization').toBeTruthy();
    const [org] = (await created.json()) as { id: string }[];
    await logout(page);

    try {
      await loginAs(page, 'finance');
      const fin = await captureRestSession(page);

      await test.step('finance can still READ organizations (invoice / PO workflows need it)', async () => {
        const rows = await restSelect(page, fin, `organizations?id=eq.${org.id}&select=id,company_code`);
        expect(rows).toHaveLength(1);
      });

      await test.step('finance cannot INSERT', async () => {
        const res = await restInsert(page, fin, 'organizations', {
          tenant_id: tenantId,
          company_code: `${code}X`,
          site_name: 'Intruder Site',
        });
        expect(res.ok(), `INSERT should be refused, got ${res.status()}`).toBeFalsy();
      });

      await test.step('finance cannot UPDATE', async () => {
        const res = await restUpdate(page, fin, 'organizations', `id=eq.${org.id}`, { site_name: 'Hacked' });
        expect(await wasRefusedOrNoOp(res), 'UPDATE must be refused or change no rows').toBeTruthy();
      });

      await test.step('finance cannot DELETE', async () => {
        const res = await restDelete(page, fin, 'organizations', `id=eq.${org.id}`);
        expect(await wasRefusedOrNoOp(res), 'DELETE must be refused or remove no rows').toBeTruthy();
      });

      await test.step('the organization is unchanged', async () => {
        const rows = (await restSelect(page, fin, `organizations?id=eq.${org.id}&select=site_name`)) as {
          site_name: string;
        }[];
        expect(rows).toEqual([{ site_name: 'Guarded Site' }]);
      });
    } finally {
      await page.context().clearCookies();
      await page.evaluate(() => localStorage.clear());
      await loginAs(page, 'companyAdmin');
      const cleanup = await captureRestSession(page);
      await restDelete(page, cleanup, 'organizations', `company_code=like.${code}*`);
    }
  });
});

import type { Mock } from 'vitest';

// Shared by the BD "lookup admin" CRUD pages under
// modules/portals/business-development/pages/admin/ -- LeadSourcesAdmin,
// ProposalTypesAdmin, TenderTypesAdmin, ClientCategoriesAdmin,
// LeadStatusesAdmin, ProposalStatusesAdmin, OpportunityStagesAdmin.
//
// They're all the same shape: a single Supabase table, a
// select().order() fetch on mount, and insert/update/delete driven by a
// dialog form. This mocks one table's worth of that chain and records
// every call so a test can assert on payloads without caring about the
// page's internal query-builder plumbing.
//
// Each page queries exactly one domain table plus `app_users`, which
// resolveTenantId() reads to resolve the caller's tenant on insert --
// the mock answers that lookup with `tenantId` (default "t1") so create
// flows keep working, and throws for any other table name -- that's
// usually a copy-paste bug in the page itself (wrong table name), which
// is exactly the kind of thing worth catching here.

interface TableMockOptions {
  rows?: unknown[];
  selectError?: { message: string } | null;
  insertError?: { message: string } | null;
  updateError?: { message: string } | null;
  deleteError?: { message: string } | null;
  tenantId?: string;
}

export function mockSupabaseTable(mockFrom: Mock, table: string, options: TableMockOptions = {}) {
  const state = {
    rows: options.rows ?? [],
    selectError: options.selectError ?? null,
    insertError: options.insertError ?? null,
    updateError: options.updateError ?? null,
    deleteError: options.deleteError ?? null,
    tenantId: options.tenantId ?? 't1',
  };

  const calls = {
    selectCount: 0,
    inserts: [] as unknown[],
    updates: [] as Array<{ payload: unknown; id: string }>,
    deletes: [] as string[],
  };

  mockFrom.mockImplementation((calledTable: string) => {
    if (calledTable === 'app_users') {
      return {
        select: () => ({
          eq: () => ({
            single: () => Promise.resolve({ data: { tenant_id: state.tenantId }, error: null }),
          }),
        }),
      };
    }
    if (calledTable !== table) {
      throw new Error(
        `mockSupabaseTable: expected supabase.from("${table}"), got supabase.from("${calledTable}")`,
      );
    }
    return {
      select: () => ({
        order: () => {
          calls.selectCount++;
          return Promise.resolve({ data: state.rows, error: state.selectError });
        },
      }),
      insert: (payload: unknown) => {
        calls.inserts.push(payload);
        return Promise.resolve({ error: state.insertError });
      },
      update: (payload: unknown) => ({
        eq: (_column: string, id: string) => {
          calls.updates.push({ payload, id });
          return Promise.resolve({ error: state.updateError });
        },
      }),
      delete: () => ({
        eq: (_column: string, id: string) => {
          calls.deletes.push(id);
          return Promise.resolve({ error: state.deleteError });
        },
      }),
    };
  });

  return { state, calls };
}

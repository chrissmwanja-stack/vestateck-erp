import type { Mock } from 'vitest';

// Shared by the IT Support pages that read/write through the RPC layer
// added in 20260820120000_it_support_admin_tier_write_rpcs.sql --
// TicketCategoriesAdmin, SlaPoliciesAdmin, PriorityLevelsAdmin,
// SupportTeamsAdmin, TicketApprovals -- rather than the BD lookup admin
// pages' direct supabase.from() CRUD (see lookupAdminHarness.ts).
//
// Each of these pages fires a batch of named RPCs on mount (often via
// Promise.all, e.g. is_it_support + get_ticket_categories) and later
// calls write RPCs from dialogs/buttons. This mocks supabase.rpc() as a
// dispatcher over per-call-name handlers and records every invocation
// (name + args, in call order) so a test can assert on both the read
// fan-out and the exact write payload without caring about Promise.all
// ordering.
//
// Handlers are plain functions, not fixed data, so a test can make a
// write handler mutate the same array a read handler returns -- the
// same "create/update, then the refetch reflects it" shape the BD
// harness gets from mockSupabaseTable's shared `rows` state.
//
// Throws if an rpc name is called with no handler registered -- that's
// usually either a copy-paste bug in the page (wrong rpc name) or a
// test that forgot to stub a call the page actually makes.

type RpcResult = { data?: unknown; error?: unknown };
type RpcHandler = (args: unknown) => RpcResult | Promise<RpcResult>;

type RpcCall = { fn: string; args: unknown };
type RpcCallLog = RpcCall[] & { callsTo: (fn: string) => RpcCall[] };

export function mockSupabaseRpc(mockRpc: Mock, handlers: Record<string, RpcHandler>) {
  const calls = [] as unknown as RpcCallLog;
  // `callsTo` lives on the array itself (not just as a sibling return
  // property) so callers can destructure either `{ calls }` and do
  // `calls.callsTo(fn)`, or `{ calls, callsTo }` and call `callsTo(fn)`
  // directly -- both shapes are used across the IT admin test files.
  calls.callsTo = (fn: string) => calls.filter((c) => c.fn === fn);

  mockRpc.mockImplementation((fn: string, args?: unknown) => {
    calls.push({ fn, args });
    const handler = handlers[fn];
    if (!handler) {
      throw new Error(
        `mockSupabaseRpc: no handler registered for rpc "${fn}" (args: ${JSON.stringify(args)})`,
      );
    }
    return Promise.resolve(handler(args));
  });

  return {
    calls,
    callsTo: calls.callsTo,
  };
}
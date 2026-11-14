// Test stand-in for https://deno.land/std@0.224.0/http/server.ts.
// Each function calls serve(handler) at module load; capture the handler so a
// test can invoke it directly with a Request.
export function serve(handler: (req: Request) => Response | Promise<Response>): void {
  const slot = (globalThis as { __edge?: { handler?: unknown } }).__edge;
  if (!slot) throw new Error('edge harness not initialised: call loadHandler() first');
  slot.handler = handler;
}

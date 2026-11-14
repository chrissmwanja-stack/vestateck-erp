// Test stand-in for https://esm.sh/@supabase/supabase-js@2.45.0.
// Delegates to the FakeSupabase the current test installed on globalThis.
import type { FakeSupabase } from '../harness';

export function createClient(url: string, key: string, opts?: unknown) {
  const slot = (globalThis as { __edge?: { fake?: FakeSupabase } }).__edge;
  if (!slot?.fake) throw new Error('edge harness not initialised: call loadHandler() first');
  return slot.fake.makeClient(url, key, opts);
}

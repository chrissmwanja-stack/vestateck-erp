/* eslint-disable @typescript-eslint/no-explicit-any */
import { supabase } from '../../../lib/supabaseClient';
import { friendlyError } from './logic';

// The generated Database types do not include the insurance tables or RPCs yet
// (same situation as platform_modules; see lib/useModuleRegistry.ts). Calls go
// through this loose view of the client, and the result shapes are typed in types.ts.
// Regenerate packages/shared/src/database.types.ts to remove the casts.

type QueryResult = { data: unknown; error: { message: string } | null };
interface LooseClient {
  from: (table: string) => any;
  rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<QueryResult>;
}
const db = supabase as unknown as LooseClient;

/** Table or view builder (select / eq / order / insert / update / delete). */
export function table(name: string): any {
  return db.from(name);
}

/** Awaits a query builder and returns its rows, or throws the friendly message. */
export async function rows<T>(builder: PromiseLike<QueryResult>): Promise<T[]> {
  const { data, error } = await builder;
  if (error) throw new Error(friendlyError(error.message));
  return (data ?? []) as T[];
}

/** Awaits a write and returns nothing, or throws the friendly message. */
export async function write(builder: PromiseLike<QueryResult>): Promise<void> {
  const { error } = await builder;
  if (error) throw new Error(friendlyError(error.message));
}

/** Calls an RPC. Returns its result, or throws the friendly message. */
export async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(friendlyError(error.message));
  return data as T;
}

export const errorText = (e: unknown): string => (e instanceof Error ? e.message : 'Something went wrong');

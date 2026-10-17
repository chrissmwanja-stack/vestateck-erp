/* eslint-disable @typescript-eslint/no-explicit-any */
import type { Database } from '@erp-platform/shared';
import { supabase } from '../../../lib/supabaseClient';
import { friendlyError } from './logic';

// Table, view and function NAMES are checked against the generated Database
// types, so a typo or a renamed object fails the build instead of failing at
// runtime. Query shapes stay loose on purpose: result rows are typed in types.ts,
// and the builders are used with a few patterns (joins, filters) that the
// generated generics make awkward. Regenerate packages/shared/src/database.types.ts
// after every migration so the name lists stay current.

type PublicSchema = Database['public'];
export type TableName = keyof PublicSchema['Tables'] | keyof PublicSchema['Views'];
export type RpcName = keyof PublicSchema['Functions'];

type QueryResult = { data: unknown; error: { message: string } | null };
interface LooseClient {
  from: (table: string) => any;
  rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<QueryResult>;
}
const db = supabase as unknown as LooseClient;

/** Table or view builder (select / eq / order / insert / update / delete). */
export function table(name: TableName): any {
  return db.from(name);
}

/** Awaits a query builder and returns its rows, or throws the friendly message. */
export async function rows<T>(builder: PromiseLike<QueryResult>): Promise<T[]> {
  const { data, error } = await builder;
  if (error) throw new Error(friendlyError(error.message));
  return (data ?? []) as T[];
}

/** Rows fetched per request by allRows(). Kept at or below the API's per-response row cap. */
export const PAGE_SIZE = 500;

/**
 * Returns every row of a query, a page at a time. Without this a plain select stops
 * silently at the API's row cap, so lists and KPIs would be wrong past that size.
 *
 * `makeQuery` is called once per page and must order by a unique key (add
 * `.order('id')` after any other ordering) or rows can repeat or go missing between
 * pages. A builder without `.range` (a test double) is awaited once.
 */
export async function allRows<T>(makeQuery: () => any, pageSize: number = PAGE_SIZE): Promise<T[]> {
  const all: T[] = [];
  for (let offset = 0; ; offset += pageSize) {
    const query = makeQuery();
    if (typeof query.range !== 'function') return rows<T>(query);
    const page = await rows<T>(query.range(offset, offset + pageSize - 1));
    all.push(...page);
    if (page.length < pageSize) return all;
  }
}

/** Awaits a write and returns nothing, or throws the friendly message. */
export async function write(builder: PromiseLike<QueryResult>): Promise<void> {
  const { error } = await builder;
  if (error) throw new Error(friendlyError(error.message));
}

/** Calls an RPC. Returns its result, or throws the friendly message. */
export async function rpc<T>(fn: RpcName, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(friendlyError(error.message));
  return data as T;
}

export const errorText = (e: unknown): string => (e instanceof Error ? e.message : 'Something went wrong');

type QueryCall = { table: string; method: string; args: unknown[] };
type QueryResult = { data: unknown[]; error: unknown };

interface QueryChain extends PromiseLike<QueryResult> {
  select(...args: unknown[]): QueryChain;
  order(...args: unknown[]): QueryChain;
  ilike(...args: unknown[]): QueryChain;
  gte(...args: unknown[]): QueryChain;
  lte(...args: unknown[]): QueryChain;
  eq(...args: unknown[]): QueryChain;
  in(...args: unknown[]): QueryChain;
  single(): Promise<{ data: unknown; error: unknown }>;
  insert(payload: Record<string, unknown>): unknown;
  update(payload: Record<string, unknown>): unknown;
}

export function createQueryLog() {
  const calls: QueryCall[] = [];

  return {
    reset() {
      calls.length = 0;
    },
    callsTo(table: string, method?: string) {
      return calls.filter((call) => call.table === table && (!method || call.method === method));
    },
    chain(table: string, data: unknown[], error: unknown = null): QueryChain {
      const record = (method: string, args: unknown[]) => {
        calls.push({ table, method, args });
      };
      const chain: QueryChain = {
        select: (...args) => {
          record('select', args);
          return chain;
        },
        order: (...args) => {
          record('order', args);
          return chain;
        },
        ilike: (...args) => {
          record('ilike', args);
          return chain;
        },
        gte: (...args) => {
          record('gte', args);
          return chain;
        },
        lte: (...args) => {
          record('lte', args);
          return chain;
        },
        eq: (...args) => {
          record('eq', args);
          return chain;
        },
        in: (...args) => {
          record('in', args);
          return chain;
        },
        single: () => Promise.resolve({ data: data[0] ?? null, error }),
        insert: () => undefined,
        update: () => undefined,
        then: (onfulfilled, onrejected) =>
          Promise.resolve({ data, error }).then(onfulfilled, onrejected),
      };
      return chain;
    },
  };
}

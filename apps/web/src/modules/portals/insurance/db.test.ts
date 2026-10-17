import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../lib/supabaseClient', () => ({ supabase: { from: vi.fn(), rpc: vi.fn() } }));

import { allRows } from './db';

// A query double that serves `total` numbered rows and records every range asked for.
function pagedSource(total: number) {
  const ranges: Array<[number, number]> = [];
  const make = () => ({
    range: (from: number, to: number) => {
      ranges.push([from, to]);
      const data = Array.from({ length: Math.max(0, Math.min(to + 1, total) - from) }, (_, i) => ({ id: from + i }));
      return Promise.resolve({ data, error: null });
    },
  });
  return { make, ranges };
}

describe('allRows', () => {
  it('returns every row across several pages', async () => {
    const { make, ranges } = pagedSource(1250);
    const result = await allRows<{ id: number }>(make, 500);
    expect(result).toHaveLength(1250);
    expect(result[0].id).toBe(0);
    expect(result[1249].id).toBe(1249);
    expect(ranges).toEqual([[0, 499], [500, 999], [1000, 1499]]);
  });

  it('asks for one more page when the last page is exactly full, then stops', async () => {
    const { make, ranges } = pagedSource(1000);
    const result = await allRows<{ id: number }>(make, 500);
    expect(result).toHaveLength(1000);
    expect(ranges).toEqual([[0, 499], [500, 999], [1000, 1499]]);
  });

  it('returns an empty list for an empty source', async () => {
    const { make } = pagedSource(0);
    expect(await allRows(make, 500)).toEqual([]);
  });

  it('awaits a builder without range once', async () => {
    const make = vi.fn(() => ({
      then: (resolve: (v: unknown) => void) => resolve({ data: [{ id: 1 }, { id: 2 }], error: null }),
    }));
    expect(await allRows(make as never, 500)).toEqual([{ id: 1 }, { id: 2 }]);
    expect(make).toHaveBeenCalledTimes(1);
  });

  it('throws the friendly message when a page fails', async () => {
    const make = () => ({
      range: () => Promise.resolve({ data: null, error: { message: 'INS_NOT_ALLOWED: nope' } }),
    });
    await expect(allRows(make, 500)).rejects.toThrow('nope');
  });
});

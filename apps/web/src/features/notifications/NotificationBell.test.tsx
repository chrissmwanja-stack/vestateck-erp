import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import NotificationBell from './NotificationBell';

let items: Record<string, unknown>[] = [];
const updates: Record<string, unknown>[] = [];

vi.mock('../../lib/supabaseClient', () => {
  const selectChain = () => {
    const chain: Record<string, unknown> = {};
    for (const m of ['select', 'eq', 'order']) chain[m] = vi.fn(() => chain);
    chain.limit = vi.fn(() => Promise.resolve({ data: items, error: null }));
    return chain;
  };
  const updateChain = (patch: Record<string, unknown>) => {
    updates.push(patch);
    const chain: Record<string, unknown> = {};
    chain.eq = vi.fn(() => chain);
    chain.is = vi.fn(() => Promise.resolve({ error: null }));
    (chain as { then: unknown }).then = (resolve: (v: unknown) => void) => resolve({ error: null });
    return chain;
  };
  const channel = { on: vi.fn(() => channel), subscribe: vi.fn(() => channel) };
  return {
    supabase: {
      from: () => ({ ...selectChain(), update: (patch: Record<string, unknown>) => updateChain(patch) }),
      channel: () => channel,
      removeChannel: vi.fn(),
    },
  };
});

const note = (over: Record<string, unknown>) => ({
  id: 'n', type: 't', title: 'Title', body: 'Body', request_id: null, purchase_order_id: null,
  link_path: null, recipient_id: 'u1', read_at: null, created_at: '2026-10-22T08:00:00Z', ...over,
});

function Where() {
  return <div data-testid="where">{useLocation().pathname}</div>;
}

function mount() {
  render(
    <MemoryRouter initialEntries={['/start']}>
      <NotificationBell userId="u1" />
      <Routes><Route path="*" element={<Where />} /></Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  updates.length = 0;
  items = [
    note({ id: 'n1', title: 'Claim approved: CLM-1', link_path: '/insurance/claims/c1' }),
    note({ id: 'n2', title: 'Leave approved' }),
  ];
});

describe('notification bell', () => {
  it('opens the linked page and marks the notification read', async () => {
    mount();
    await userEvent.click(screen.getByLabelText('notifications'));
    await userEvent.click(await screen.findByText('Claim approved: CLM-1'));
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/insurance/claims/c1'));
    expect(updates.some((u) => 'read_at' in u)).toBe(true);
  });

  it('only marks read when a notification has no link', async () => {
    mount();
    await userEvent.click(screen.getByLabelText('notifications'));
    await userEvent.click(await screen.findByText('Leave approved'));
    expect(screen.getByTestId('where').textContent).toBe('/start');
    await waitFor(() => expect(updates.some((u) => 'read_at' in u)).toBe(true));
  });
});

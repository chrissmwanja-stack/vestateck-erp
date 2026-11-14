import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import LeaveRequestsList from './LeaveRequestsList';

// HR can file leave for anyone, but nobody decides their own request: the
// Approve / Reject actions are hidden on the signed-in user's own request.
// (The database refuses it as well; see test_hr_leave_on_behalf_and_self_approval.sql.)

const rows = vi.hoisted(() => ({
  hr_leave_requests: [
    { id: 'r1', employee_id: 'e-me', leave_type_id: 'lt', start_date: '2026-12-01', end_date: '2026-12-02', days: 2, reason: null, status: 'pending', created_at: '2026-11-01', hr_employees: { first_name: 'Me', last_name: 'Self' }, hr_leave_types: { name: 'Annual' } },
    { id: 'r2', employee_id: 'e-other', leave_type_id: 'lt', start_date: '2026-12-05', end_date: '2026-12-06', days: 2, reason: null, status: 'pending', created_at: '2026-11-02', hr_employees: { first_name: 'Other', last_name: 'Person' }, hr_leave_types: { name: 'Annual' } },
  ],
  hr_employees: [
    { id: 'e-me', first_name: 'Me', last_name: 'Self', user_id: 'user-me' },
    { id: 'e-other', first_name: 'Other', last_name: 'Person', user_id: 'user-other' },
  ],
  hr_leave_types: [{ id: 'lt', name: 'Annual', days_per_year: 21 }],
}));

vi.mock('../../../../../lib/supabaseClient', () => {
  const chain = (table: keyof typeof rows) => {
    const c: Record<string, unknown> = {};
    for (const m of ['select', 'eq', 'order']) c[m] = vi.fn(() => c);
    c.then = (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) =>
      Promise.resolve({ data: rows[table], error: null }).then(resolve, reject);
    return c;
  };
  return { supabase: { from: (t: keyof typeof rows) => chain(t) } };
});
vi.mock('../../../../../lib/authContext', () => ({
  useAuth: () => ({ session: { user: { id: 'user-me' } } }),
}));

describe('LeaveRequestsList: no self-approval', () => {
  it('shows Approve/Reject only on other people\'s pending requests', async () => {
    render(<MemoryRouter><LeaveRequestsList /></MemoryRouter>);
    await screen.findByText('Other Person');
    expect(screen.getAllByRole('button', { name: 'Approve' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: 'Reject' })).toHaveLength(1);
    expect(screen.getByText('Needs another approver')).toBeTruthy();
  });
});

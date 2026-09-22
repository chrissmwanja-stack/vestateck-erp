import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { ToastProvider, useToast } from './toastContext';

function Trigger() {
  const { showToast, showError, showSuccess } = useToast();
  return (
    <div>
      <button onClick={() => showToast('Plain message')}>plain</button>
      <button onClick={() => showToast('Warned', 'warning')}>warn</button>
      <button onClick={() => showError('Something failed')}>error</button>
      <button onClick={() => showSuccess('Saved')}>success</button>
    </div>
  );
}

describe('ToastProvider / useToast', () => {
  it('shows a toast with the default "info" severity when none is given', async () => {
    render(
      <ToastProvider>
        <Trigger />
      </ToastProvider>,
    );

    screen.getByRole('button', { name: 'plain' }).click();

    await waitFor(() => expect(screen.getByText('Plain message')).toBeInTheDocument());
    expect(screen.getByRole('alert')).toHaveClass('MuiAlert-filledInfo', { exact: false });
  });

  it('honours an explicit severity passed to showToast', async () => {
    render(
      <ToastProvider>
        <Trigger />
      </ToastProvider>,
    );

    screen.getByRole('button', { name: 'warn' }).click();

    await waitFor(() => expect(screen.getByText('Warned')).toBeInTheDocument());
    expect(screen.getByRole('alert')).toHaveClass('MuiAlert-filledWarning', { exact: false });
  });

  it('showError shows the message with "error" severity', async () => {
    render(
      <ToastProvider>
        <Trigger />
      </ToastProvider>,
    );

    screen.getByRole('button', { name: 'error' }).click();

    await waitFor(() => expect(screen.getByText('Something failed')).toBeInTheDocument());
    expect(screen.getByRole('alert')).toHaveClass('MuiAlert-filledError', { exact: false });
  });

  it('showSuccess shows the message with "success" severity', async () => {
    render(
      <ToastProvider>
        <Trigger />
      </ToastProvider>,
    );

    screen.getByRole('button', { name: 'success' }).click();

    await waitFor(() => expect(screen.getByText('Saved')).toBeInTheDocument());
    expect(screen.getByRole('alert')).toHaveClass('MuiAlert-filledSuccess', { exact: false });
  });

  it('queues a second toast and shows it only after the first has closed', async () => {
    render(
      <ToastProvider>
        <Trigger />
      </ToastProvider>,
    );

    screen.getByRole('button', { name: 'plain' }).click();
    await waitFor(() => expect(screen.getByText('Plain message')).toBeInTheDocument());

    // Queue the second message while the first is still showing -- it must
    // not appear yet, and the first must not be replaced early.
    screen.getByRole('button', { name: 'success' }).click();
    expect(screen.queryByText('Saved')).not.toBeInTheDocument();
    expect(screen.getByText('Plain message')).toBeInTheDocument();

    // Dismiss the first by clicking its own close button so the queue
    // advances via the real onExited transition, matching production
    // behaviour rather than force-unmounting.
    screen.getByRole('button', { name: /close/i }).click();

    await waitFor(() => expect(screen.getByText('Saved')).toBeInTheDocument(), { timeout: 5000 });
    expect(screen.queryByText('Plain message')).not.toBeInTheDocument();
  });

  it('throws when useToast is called outside a ToastProvider', () => {
    const BareTrigger = () => {
      useToast();
      return null;
    };
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    expect(() => render(<BareTrigger />)).toThrow('useToast must be used within a ToastProvider');
    spy.mockRestore();
  });
});
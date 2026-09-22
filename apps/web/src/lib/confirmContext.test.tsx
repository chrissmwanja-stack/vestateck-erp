import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { ConfirmProvider, useConfirm } from './confirmContext';

function Trigger({ onResult }: { onResult: (result: boolean) => void }) {
  const confirm = useConfirm();
  return (
    <button
      onClick={async () => {
        const result = await confirm('Delete this record?');
        onResult(result);
      }}
    >
      Delete
    </button>
  );
}

function TitledTrigger({ onResult }: { onResult: (result: boolean) => void }) {
  const confirm = useConfirm();
  return (
    <button
      onClick={async () => {
        const result = await confirm({
          title: 'Delete record',
          message: 'This cannot be undone.',
          confirmLabel: 'Delete',
          tone: 'danger',
        });
        onResult(result);
      }}
    >
      Open
    </button>
  );
}

describe('ConfirmProvider / useConfirm', () => {
  it('resolves true when the confirm button is clicked', async () => {
    const onResult = vi.fn();
    render(
      <ConfirmProvider>
        <Trigger onResult={onResult} />
      </ConfirmProvider>,
    );

    screen.getByRole('button', { name: 'Delete' }).click();
    await waitFor(() => expect(screen.getByText('Delete this record?')).toBeInTheDocument());

    screen.getByRole('button', { name: 'Confirm' }).click();

    await waitFor(() => expect(onResult).toHaveBeenCalledWith(true));
  });

  it('resolves false when cancel is clicked', async () => {
    const onResult = vi.fn();
    render(
      <ConfirmProvider>
        <Trigger onResult={onResult} />
      </ConfirmProvider>,
    );

    screen.getByRole('button', { name: 'Delete' }).click();
    await waitFor(() => expect(screen.getByText('Delete this record?')).toBeInTheDocument());

    screen.getByRole('button', { name: 'Cancel' }).click();

    await waitFor(() => expect(onResult).toHaveBeenCalledWith(false));
  });

  it('uses the default title "Are you sure?" for the shorthand string form', async () => {
    render(
      <ConfirmProvider>
        <Trigger onResult={() => {}} />
      </ConfirmProvider>,
    );

    screen.getByRole('button', { name: 'Delete' }).click();

    await waitFor(() => expect(screen.getByText('Are you sure?')).toBeInTheDocument());
  });

  it('honours custom title, message, and confirmLabel from the options object', async () => {
    const onResult = vi.fn();
    render(
      <ConfirmProvider>
        <TitledTrigger onResult={onResult} />
      </ConfirmProvider>,
    );

    screen.getByRole('button', { name: 'Open' }).click();

    await waitFor(() => expect(screen.getByText('Delete record')).toBeInTheDocument());
    expect(screen.getByText('This cannot be undone.')).toBeInTheDocument();

    // "Delete" appears as the confirmLabel here (distinct from the earlier
    // shorthand test's default "Confirm" label).
    screen.getByRole('button', { name: 'Delete' }).click();
    await waitFor(() => expect(onResult).toHaveBeenCalledWith(true));
  });

  it('throws when useConfirm is called outside a ConfirmProvider', () => {
    const BareTrigger = () => {
      useConfirm();
      return null;
    };
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    expect(() => render(<BareTrigger />)).toThrow('useConfirm must be used within a ConfirmProvider');
    spy.mockRestore();
  });
});
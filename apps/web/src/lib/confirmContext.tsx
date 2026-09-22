import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from 'react';
import { Button, Dialog, DialogActions, DialogContent, DialogContentText, DialogTitle } from '@mui/material';

export interface ConfirmOptions {
  /** Defaults to "Are you sure?" */
  title?: string;
  /** Required -- the question being asked. */
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  /** "danger" renders the confirm button in the error color, for destructive actions. */
  tone?: 'default' | 'danger';
}

type ConfirmFn = (options: ConfirmOptions | string) => Promise<boolean>;

const ConfirmContext = createContext<ConfirmFn | undefined>(undefined);

/**
 * App-wide replacement for native confirm(). Wrap the app once in
 * main.tsx; call useConfirm() anywhere below it.
 *
 * Usage mirrors the old pattern closely so call sites are a near
 * mechanical swap:
 *   // before: if (!confirm(`Mark proposal as ${decision}?`)) return;
 *   // after:  if (!await confirm(`Mark proposal as ${decision}?`)) return;
 */
export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [options, setOptions] = useState<ConfirmOptions | null>(null);
  const [open, setOpen] = useState(false);
  const resolveRef = useRef<((value: boolean) => void) | null>(null);

  const confirm = useCallback<ConfirmFn>((opts) => {
    const normalized: ConfirmOptions = typeof opts === 'string' ? { message: opts } : opts;
    setOptions(normalized);
    setOpen(true);
    return new Promise<boolean>((resolve) => {
      resolveRef.current = resolve;
    });
  }, []);

  const settle = (value: boolean) => {
    setOpen(false);
    resolveRef.current?.(value);
    resolveRef.current = null;
  };

  return (
    <ConfirmContext.Provider value={confirm}>
      {children}
      <Dialog open={open} onClose={() => settle(false)} maxWidth="xs" fullWidth>
        <DialogTitle>{options?.title ?? 'Are you sure?'}</DialogTitle>
        <DialogContent>
          <DialogContentText>{options?.message}</DialogContentText>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => settle(false)}>{options?.cancelLabel ?? 'Cancel'}</Button>
          <Button
            onClick={() => settle(true)}
            variant="contained"
            color={options?.tone === 'danger' ? 'error' : 'primary'}
            autoFocus
          >
            {options?.confirmLabel ?? 'Confirm'}
          </Button>
        </DialogActions>
      </Dialog>
    </ConfirmContext.Provider>
  );
}

export function useConfirm(): ConfirmFn {
  const ctx = useContext(ConfirmContext);
  if (!ctx) throw new Error('useConfirm must be used within a ConfirmProvider');
  return ctx;
}
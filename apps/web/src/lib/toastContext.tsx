import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { Alert, Snackbar } from '@mui/material';

export type ToastSeverity = 'success' | 'error' | 'warning' | 'info';

interface ToastMessage {
  key: number;
  message: string;
  severity: ToastSeverity;
}

interface ToastContextValue {
  /** Replacement for native alert(message). Defaults to severity "info". */
  showToast: (message: string, severity?: ToastSeverity) => void;
  /** Convenience wrapper for the common "request failed" case. */
  showError: (message: string) => void;
  /** Convenience wrapper for a successful save/action. */
  showSuccess: (message: string) => void;
}

const ToastContext = createContext<ToastContextValue | undefined>(undefined);

/**
 * App-wide replacement for native alert(). Wrap the app once in main.tsx;
 * call useToast() anywhere below it. Messages queue one at a time (same
 * UX as a single Snackbar, just multi-message safe) rather than stacking,
 * to match the existing per-screen Snackbar pattern used in
 * ContractApprovals.tsx / FilingsList.tsx etc.
 */
export function ToastProvider({ children }: { children: ReactNode }) {
  const [queue, setQueue] = useState<ToastMessage[]>([]);
  const [current, setCurrent] = useState<ToastMessage | null>(null);
  const [open, setOpen] = useState(false);
  const nextKey = useRef(0);

  const showToast = useCallback((message: string, severity: ToastSeverity = 'info') => {
    const entry: ToastMessage = { key: nextKey.current++, message, severity };
    setQueue((prev) => [...prev, entry]);
  }, []);

  const showError = useCallback((message: string) => showToast(message, 'error'), [showToast]);
  const showSuccess = useCallback((message: string) => showToast(message, 'success'), [showToast]);

  // Advance the queue only once the previously-shown message has actually
  // finished its exit transition (current === null, set in onExited below).
  // Gating on `open` instead of `current` would re-open the Snackbar with
  // the same still-queued message the instant handleClose sets open=false
  // -- i.e. before the close animation ever gets to play -- so the toast
  // would appear to never close.
  useEffect(() => {
    if (current === null && queue.length > 0) {
      setCurrent(queue[0]);
      setOpen(true);
    }
  }, [current, queue]);

  const handleClose = (_event?: unknown, reason?: string) => {
    if (reason === 'clickaway') return;
    setOpen(false);
  };

  const handleExited = () => {
    setQueue((prev) => prev.slice(1));
    setCurrent(null);
  };

  return (
    <ToastContext.Provider value={{ showToast, showError, showSuccess }}>
      {children}
      <Snackbar
        open={open}
        autoHideDuration={4000}
        onClose={handleClose}
        TransitionProps={{ onExited: handleExited }}
        anchorOrigin={{ vertical: 'bottom', horizontal: 'center' }}
      >
        {current ? (
          <Alert onClose={handleClose} severity={current.severity} variant="filled" sx={{ width: '100%' }}>
            {current.message}
          </Alert>
        ) : undefined}
      </Snackbar>
    </ToastContext.Provider>
  );
}

export function useToast(): ToastContextValue {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error('useToast must be used within a ToastProvider');
  return ctx;
}
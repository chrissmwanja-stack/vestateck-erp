// Client-side error tracking (gap #3).
//
// Dependency-free: unhandled errors and promise rejections are POSTed to
// /api/client-errors (a Vercel function whose logs feed the log drain).
// To move to Sentry later, swap reportError()'s body for Sentry.captureException.

interface ErrorReport {
  message: string;
  stack?: string;
  source?: string;
  lineno?: number;
  colno?: number;
  url: string;
  userAgent: string;
  at: string;
}

let installed = false;

export function reportError(error: unknown, extra?: Record<string, unknown>) {
  try {
    const err = error instanceof Error ? error : new Error(String(error));
    const body: ErrorReport & { extra?: Record<string, unknown> } = {
      message: err.message,
      stack: err.stack,
      url: window.location.href,
      userAgent: navigator.userAgent,
      at: new Date().toISOString(),
      extra,
    };
    void fetch('/api/client-errors', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      keepalive: true, // survives page unload
    }).catch(() => { /* never let reporting break the app */ });
  } catch { /* ignore */ }
}

/** Installs window-level handlers. Call once from main.tsx. */
export function installErrorTracking() {
  if (installed || typeof window === 'undefined') return;
  installed = true;

  window.addEventListener('error', (e) => {
    reportError(e.error ?? e.message, { source: e.filename, lineno: e.lineno, colno: e.colno });
  });
  window.addEventListener('unhandledrejection', (e) => {
    reportError(e.reason, { type: 'unhandledrejection' });
  });
}

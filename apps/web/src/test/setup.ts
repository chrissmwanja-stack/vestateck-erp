import '@testing-library/jest-dom/vitest';
import { afterEach } from 'vitest';
import { cleanup } from '@testing-library/react';

// @testing-library/react's automatic afterEach cleanup only registers
// itself when Vitest's `globals: true` is set. We don't set that (to
// keep test helpers explicitly imported rather than ambient globals),
// so unmount the previous test's render manually -- otherwise elements
// from one test can still be in the DOM when the next test's
// assertions run.
afterEach(() => {
  cleanup();
});

// Newer Node versions (22.4+/25) ship an experimental global `localStorage`
// that is `undefined` unless Node is started with --localstorage-file. It
// shadows jsdom's Storage, so `localStorage.getItem(...)` throws
// "Cannot read properties of undefined". If the global is unusable, install
// a small in-memory Storage on both globalThis and window so tests behave
// the same on every Node version.
function installStorage(name: 'localStorage' | 'sessionStorage') {
  let usable = false;
  try {
    usable =
  typeof (globalThis as unknown as Record<string, { getItem?: unknown } | undefined>)[name]?.getItem ===
  'function';
  } catch {
    usable = false;
  }
  if (usable) return;

  const data = new Map<string, string>();
  const storage: Storage = {
    get length() {
      return data.size;
    },
    clear: () => data.clear(),
    getItem: (k) => (data.has(String(k)) ? data.get(String(k))! : null),
    key: (i) => Array.from(data.keys())[i] ?? null,
    removeItem: (k) => void data.delete(String(k)),
    setItem: (k, v) => void data.set(String(k), String(v)),
  };
  for (const target of [globalThis, window] as object[]) {
    Object.defineProperty(target, name, { value: storage, configurable: true, writable: true });
  }
}

installStorage('localStorage');
installStorage('sessionStorage');

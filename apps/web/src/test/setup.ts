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
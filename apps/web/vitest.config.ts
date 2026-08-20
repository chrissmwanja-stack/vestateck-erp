import { defineConfig } from 'vitest/config';

// Deliberately minimal for now: this project has almost no client-side
// business logic to test -- approval thresholds, payroll calculations,
// and PO settlement all live in SECURITY DEFINER SQL functions (see
// supabase/scripts and the db-shadow-replay CI job for that side).
// What *does* live client-side and is worth locking down with tests is
// the handful of pure parsing/formatting functions shared across every
// bulk-import screen (src/lib/csvParser.ts, src/lib/xlsxParser.ts) and
// any zod validation schemas as they get extracted out of form
// components. Environment is plain Node (no jsdom) since none of that
// touches the DOM -- add a jsdom project here if/when component tests
// are wanted.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html'],
      include: ['src/lib/**/*.ts'],
    },
  },
});

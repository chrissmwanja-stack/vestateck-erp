import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

// Two projects, split by environment:
//
// - "lib" (plain Node, no jsdom): the pure parsing/formatting functions
//   shared across every bulk-import screen (src/lib/csvParser.ts,
//   src/lib/xlsxParser.ts), and any zod validation schemas as they get
//   extracted out of form components. None of this touches the DOM.
//
// - "components" (jsdom + React Testing Library): route guards and
//   other components with real client-side branching logic worth
//   locking down (auth/session gating, tenant-suspension handling,
//   role-based redirects). Most screens are thin Supabase CRUD forms
//   with little logic of their own -- those stay covered by the
//   db-shadow-replay CI job and the SECURITY DEFINER SQL functions
//   they call, not component tests. This project is for the handful
//   of components where real branching happens on the client.
export default defineConfig({
  test: {
    projects: [
      {
        plugins: [react()],
        test: {
          name: 'lib',
          environment: 'node',
          include: ['src/lib/**/*.test.ts'],
        },
      },
      {
        plugins: [react()],
        test: {
          name: 'components',
          environment: 'jsdom',
          include: ['src/**/*.test.tsx'],
          setupFiles: ['./src/test/setup.ts'],
        },
      },
    ],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html'],
      include: ['src/lib/**/*.ts', 'src/features/**/*.tsx', 'src/components/**/*.tsx'],
    },
  },
});

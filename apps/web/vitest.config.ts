import { defineConfig, type Plugin } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';

// The edge functions import from https://deno.land and https://esm.sh, which
// vite-node hands straight to Node's loader (it rejects https: URLs) before any
// alias can apply. Rewrite those three specifiers to local stubs while the source
// is still plain text.
function denoUrlStubs(): Plugin {
  const toPath = (rel: string) => fileURLToPath(new URL(rel, import.meta.url)).replace(/\\/g, '/');
  const stubs: Record<string, string> = {
    'https://deno.land/std@0.224.0/http/server.ts': toPath('../../supabase/functions/__tests__/stubs/deno-serve.ts'),
    'https://esm.sh/@supabase/supabase-js@2.45.0': toPath('../../supabase/functions/__tests__/stubs/supabase-js.ts'),
    'https://esm.sh/pdf-lib@1.17.1': toPath('../../supabase/functions/__tests__/stubs/pdf-lib.ts'),
  };
  return {
    name: 'edge-deno-url-stubs',
    enforce: 'pre',
    transform(code, id) {
      if (!id.replace(/\\/g, '/').includes('/supabase/functions/')) return null;
      let out = code;
      for (const [url, stub] of Object.entries(stubs)) {
        out = out.split(`'${url}'`).join(JSON.stringify(stub)).split(`"${url}"`).join(JSON.stringify(stub));
      }
      return out === code ? null : { code: out, map: null };
    },
  };
}

// Two projects, split by environment:
//
// - "lib" (plain Node, no jsdom): the pure parsing/formatting functions
//   shared across every bulk-import screen (src/lib/csvParser.ts,
//   src/lib/xlsxParser.ts), plus any pure helpers extracted out of
//   feature screens (e.g. features/admin/renewals.ts,
//   features/company-admin/companyReadiness.ts) and zod validation
//   schemas. None of this touches the DOM.
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
          include: ['src/lib/**/*.test.ts', 'src/features/**/*.test.ts', 'src/components/**/*.test.ts', 'src/modules/**/*.test.ts'],
        },
      },
      {
        plugins: [react()],
        test: {
          name: 'components',
          environment: 'jsdom',
          include: ['src/**/*.test.tsx'],
          setupFiles: ['./src/test/setup.ts'],
          // Heavy MUI + userEvent tests take 2-3s each on a fast box but can
          // spike well past 15s under full-suite parallel contention on
          // slower machines (observed flakes at 15s); 30s keeps the
          // hang-detector meaningful without punting on loaded dev boxes.
          testTimeout: 30000,
          hookTimeout: 30000,
        },
      },
      // - "edge" (plain Node): the Supabase edge functions in
      //   supabase/functions. They are written for Deno (URL imports,
      //   Deno.env, top-level serve()), so the three URL imports are rewritten
      //   to stubs (see denoUrlStubs above) and each function is driven through the handler it
      //   registers, against a scriptable fake client. See
      //   supabase/functions/__tests__/harness.ts. Runs in the same
      //   `npm run test` CI job as everything else; no Deno needed.
      {
        plugins: [denoUrlStubs()],
        test: {
          name: 'edge',
          environment: 'node',
          include: ['../../supabase/functions/**/*.test.ts'],
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

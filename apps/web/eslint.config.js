// Rules here are enforced as RATCHETS, not as blanket errors.
//
// The older pages still contain hundreds of violations of each rule below. CI does not fail on
// those; scripts/check-lint-ratchet.mjs compares per-file counts with the eslint-*-baseline.json
// files in this folder and fails when a file gets MORE violations than its baseline (a new file's
// baseline is 0) or FEWER without the baseline being lowered, so progress is locked in. Fix a
// violation, then run `npm run lint:ratchet:baseline` and commit the changed baseline.
//
// Ratchets (registry lives in scripts/check-lint-ratchet.mjs):
//   any        @typescript-eslint/no-explicit-any            type from the generated DB types
//   dialogs    no-alert                                      alert()/confirm()/prompt() -> useToast()/useConfirm()
//   swallowed  local/supabase-no-swallowed-error             destructure { data, error }; call showError()
//   hook-deps  react-hooks/exhaustive-deps                   stale closures in effects/callbacks
// Zero tolerance (any violation fails, no baseline):
//   react-hooks/rules-of-hooks
//
// No type-aware rules, so linting needs no tsconfig and stays fast.
import tseslint from 'typescript-eslint';
import reactHooks from 'eslint-plugin-react-hooks';
import localRules from './eslint-rules/supabase-no-swallowed-error.js';

export default tseslint.config(
  {
    ignores: ['dist/**', 'node_modules/**', 'coverage/**', 'playwright-report/**', 'e2e/**', 'src/**/*.test.ts', 'src/**/*.test.tsx'],
  },
  {
    files: ['src/**/*.{ts,tsx}'],
    languageOptions: { parser: tseslint.parser },
    plugins: {
      '@typescript-eslint': tseslint.plugin,
      'react-hooks': reactHooks,
      local: localRules,
    },
    // Existing comments disable other rules (e.g. no-console) that are not configured here.
    linterOptions: { reportUnusedDisableDirectives: 'off' },
    rules: {
      '@typescript-eslint/no-explicit-any': 'error',
      'no-alert': 'error',
      'local/supabase-no-swallowed-error': 'error',
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'error',
    },
  },
);

// Deliberately minimal: one rule, `no-explicit-any`, enforced as a RATCHET.
//
// There are still a few hundred `any` uses in older pages, so the rule is "error" here
// but CI does not fail on the existing ones. scripts/check-any-ratchet.mjs compares the
// per-file counts with apps/web/eslint-any-baseline.json and fails when a file gets MORE
// `any` than its baseline (a new file's baseline is 0) or when the baseline is stale
// because a file got fewer. Fix `any` by typing from the generated database types
// (Tables<'x'>, TablesInsert<'x'>), then run `npm run lint:any:baseline`.
//
// No type-aware rules, so linting needs no tsconfig and stays fast.
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: ['dist/**', 'node_modules/**', 'coverage/**', 'playwright-report/**', 'e2e/**', 'src/**/*.test.ts', 'src/**/*.test.tsx'],
  },
  {
    files: ['src/**/*.{ts,tsx}'],
    languageOptions: { parser: tseslint.parser },
    plugins: { '@typescript-eslint': tseslint.plugin },
    // Existing comments disable other rules (e.g. no-console) that are not configured here.
    linterOptions: { reportUnusedDisableDirectives: 'off' },
    rules: { '@typescript-eslint/no-explicit-any': 'error' },
  },
);

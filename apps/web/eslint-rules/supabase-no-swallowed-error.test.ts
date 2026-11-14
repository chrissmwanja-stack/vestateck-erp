import { describe, it, afterAll } from 'vitest';
import { RuleTester } from 'eslint';
import tseslint from 'typescript-eslint';
// @ts-expect-error plain JS module, no types
import plugin from './supabase-no-swallowed-error.js';

RuleTester.describe = describe;
RuleTester.it = it;
RuleTester.itOnly = it.only;
RuleTester.afterAll = afterAll;

const tester = new RuleTester({ languageOptions: { parser: tseslint.parser } });

tester.run('supabase-no-swallowed-error', plugin.rules['supabase-no-swallowed-error'], {
  valid: [
    "async function f(){ const { data, error } = await supabase.from('t').select(); }",
    "async function f(){ const { data, error: e } = await supabase.rpc('r', {}); }",
    "async function f(){ const res = await supabase.from('t').select(); }",
    "async function f(){ const { ...rest } = await supabase.from('t').select(); }",
    "async function f(){ const { error } = await supabase.from('t').insert({}); }",
    "async function f(){ await supabase.storage.from('b').remove(['p']); }",
    "async function f(){ const { data } = await supabase.auth.getSession(); }",
    "async function f(){ const { data } = await other.from('t').select(); }",
    "async function f(){ const { data } = await fetchSomething(); }",
  ],
  invalid: [
    { code: "async function f(){ const { data } = await supabase.from('t').select(); }", errors: [{ messageId: 'dropped' }] },
    { code: "async function f(){ const { data, count } = await supabase.from('t').select('*', { count: 'exact' }); }", errors: [{ messageId: 'dropped' }] },
    { code: "async function f(){ const { data } = await supabase\n  .from('t')\n  .select()\n  .eq('a', 1)\n  .single(); }", errors: [{ messageId: 'dropped' }] },
    { code: "async function f(){ const { data } = await supabase.rpc('r', {}); }", errors: [{ messageId: 'dropped' }] },
    { code: "async function f(){ const { data } = await supabase.functions.invoke('fn'); }", errors: [{ messageId: 'dropped' }] },
    { code: "async function f(){ const { data } = await db.from('t').select(); }", errors: [{ messageId: 'dropped' }] },
    { code: "async function f(){ const { data } = (await supabase.from('t').select()) as any; }", errors: [{ messageId: 'dropped' }] },
    { code: "async function f(){ await supabase.from('t').insert({}); }", errors: [{ messageId: 'discarded' }] },
    { code: "async function f(){ await supabase.rpc('r', {}); }", errors: [{ messageId: 'discarded' }] },
  ],
});

// Local ESLint rule: a supabase-js call must not drop its `error`.
//
// supabase-js never throws on a failed request; it resolves with { data, error }. Code that
// reads only `data` (or ignores the result) renders an empty or stale screen when RLS denies
// the call or the network fails, and nothing tells the user why. This is the pattern that hid
// the ProposalApprovals bug (the old scripts/check-error-handling.sh was written after it).
//
// Flags an awaited call on the `supabase` (or `db`) client that goes through .from(), .rpc() or
// .functions.invoke() when either
//   1. its result is destructured without an `error` property, e.g. `const { data } = await ...`
//   2. its result is discarded, e.g. `await supabase.from('t').insert(row);`
// Not flagged: `const res = await ...` (res.error can be checked later), `{ data, error }`,
// `{ ...rest }`, and the .storage / .auth APIs.
//
// Known limits (a reviewer still has to watch for these): results read through
// `Promise.all([...])` array destructuring, and results passed straight to another function.

const CLIENTS = new Set(['supabase', 'db']);
const ENTRY_CALLS = new Set(['from', 'rpc']);

// Walk `supabase.from('t').select().eq(...)` down to its root identifier and report whether the
// chain used one of the data-returning entry points.
function analyseChain(node) {
  let cur = node;
  let usesEntry = false;
  let viaStorageOrAuth = false;
  while (cur) {
    if (cur.type === 'CallExpression') {
      cur = cur.callee;
    } else if (cur.type === 'MemberExpression') {
      const name = cur.property && (cur.property.name ?? cur.property.value);
      if (!cur.computed && (name === 'storage' || name === 'auth')) viaStorageOrAuth = true;
      if (!cur.computed && ENTRY_CALLS.has(name)) usesEntry = true;
      // supabase.functions.invoke(...)
      if (!cur.computed && name === 'invoke' && cur.object.type === 'MemberExpression'
          && cur.object.property.name === 'functions') usesEntry = true;
      cur = cur.object;
    } else if (cur.type === 'TSNonNullExpression' || cur.type === 'TSAsExpression') {
      cur = cur.expression;
    } else if (cur.type === 'Identifier') {
      return { root: cur.name, usesEntry: usesEntry && !viaStorageOrAuth };
    } else {
      return { root: null, usesEntry: false };
    }
  }
  return { root: null, usesEntry: false };
}

function hasErrorKey(pattern) {
  return pattern.properties.some((p) => {
    if (p.type === 'RestElement') return true; // can't tell; don't guess
    const key = p.key && (p.key.name ?? p.key.value);
    return key === 'error';
  });
}

/** @type {import('eslint').Rule.RuleModule} */
const rule = {
  meta: {
    type: 'problem',
    schema: [],
    messages: {
      dropped:
        'This supabase call drops its `error`. Destructure `{ data, error }` and surface a failure with showError() (see ProposalApprovals.tsx fetchData()).',
      discarded:
        'The result of this supabase call is discarded, so a failed request is silent. Capture `{ error }` and handle it.',
    },
  },
  create(context) {
    return {
      AwaitExpression(node) {
        const { root, usesEntry } = analyseChain(node.argument);
        if (!root || !CLIENTS.has(root) || !usesEntry) return;

        // Climb past wrappers such as `(await x)!` or `(await x) as T`.
        let parent = node.parent;
        while (parent && (parent.type === 'TSNonNullExpression' || parent.type === 'TSAsExpression')) {
          parent = parent.parent;
        }
        if (!parent) return;

        if (parent.type === 'ExpressionStatement') {
          context.report({ node, messageId: 'discarded' });
        } else if (
          parent.type === 'VariableDeclarator' &&
          parent.id.type === 'ObjectPattern' &&
          !hasErrorKey(parent.id)
        ) {
          context.report({ node, messageId: 'dropped' });
        }
      },
    };
  },
};

export default { rules: { 'supabase-no-swallowed-error': rule } };

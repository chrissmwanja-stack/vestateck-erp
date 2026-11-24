"""Compare a re-issued function against the version it replaces, by statement trace.

Usage:
    python3 scripts/verification/reissue_trace.py OLD.sql NEW.sql fn_name [fn_name ...]

Why this is a gate and not a one-off script: re-issuing a live function is where silent
regressions live, and none of the existing checks can see them. Parsing accepts a function
whose guard is unreachable. A careful diff of the text does not show that a guard now
precedes the assignment it tests. This repository has shipped that exact defect twice.

Re-issuing a live function is where silent regressions live: a checks that read the same
can be in a different ORDER, and an ordering change is not visible in a diff that a human
skims. The concrete case this exists for: a guard `if v_trust < v_total` moved above the
`select ... into v_total`, so v_total was null, the comparison was null, and the guard
became unreachable -- while still being present in the text.

The trace records, in order, only what carries behaviour:
  into <var>      a value is assigned
  raise <CODE>    a refusal
  call <fn>       another function or procedure is invoked
Formatting, comments, variable declarations and expressions are ignored on purpose: those
differ legitimately between a re-issue and its original.
"""
import re
import sys


def find_function(text, name):
    """Return the body of the single function whose qualified name ends with `name`."""
    out = []
    for m in re.finditer(r'create\s+(?:or\s+replace\s+)?function\s+([\w.]+)', text, re.I):
        qualified = m.group(1)
        short = qualified.split('.')[-1]
        if short != name:
            continue
        bstart = text.find('$$', m.start())
        bend = text.find('$$;', bstart + 2)
        if bstart < 0 or bend < 0:
            continue
        out.append(text[bstart + 2:bend])
    return out


def strip_noise(body):
    body = re.sub(r'--[^\n]*', '', body)
    body = re.sub(r"'(?:[^']|'')*'", "''", body)   # literals, so quoted text cannot match
    return body.lower()


def trace(body):
    b = strip_noise(body)
    events = []
    # Assignments only. A bare `into` also matches `insert into <table>`, which is not an
    # assignment and produced false "lost assignment" reports until this was narrowed to
    # the v_/p_ local-variable convention this codebase actually uses.
    for m in re.finditer(r'(?<!\binsert\s)(?<!\bmerge\s)into\s+((?:v_|p_)[a-z0-9_]*)\b', b):
        events.append((m.start(), f"into {m.group(1)}"))
    for m in re.finditer(r'raise\s+exception\s+\'([a-z0-9_]+)', b):
        events.append((m.start(), f"raise {m.group(1)}"))
    # original literal text was stripped, so re-read codes from the unstripped body
    orig = re.sub(r'--[^\n]*', '', body)
    code_positions = [(m.start(), f"raise {m.group(1).upper()}")
                      for m in re.finditer(r"raise\s+exception\s+'([A-Za-z0-9_]+)", orig)]
    events = [e for e in events if not e[1].startswith('raise')]
    events += code_positions
    for m in re.finditer(r'(?<![\w])(?:[a-z_][a-z0-9_]*\.)*([a-z_][a-z0-9_]{4,})\s*\(', b):
        fn = m.group(1)
        if fn in ('coalesce', 'jsonb_build_object', 'jsonb_build_array', 'format', 'btrim',
                  'length', 'cardinality', 'round', 'left', 'exists', 'case', 'array_agg',
                  'unnest', 'nullif', 'sum', 'max', 'min', 'count', 'distinct', 'values',
                  'select', 'insert', 'update', 'delete', 'exception', 'if', 'loop', 'then'):
            continue
        events.append((m.start(), f"call {fn}"))
    events.sort()
    # de-duplicate adjacent repetitions of the same event
    out, prev = [], None
    for _, e in events:
        if e != prev:
            out.append(e)
        prev = e
    return out


def compare(old_body, new_body, label):
    t_old, t_new = trace(old_body), trace(new_body)
    s_old, s_new = set(t_old), set(t_new)
    lost = [e for e in dict.fromkeys(t_old) if e not in s_new]
    added = [e for e in dict.fromkeys(t_new) if e not in s_old]
    order_problems = []
    # for the events present in both, is their relative order preserved?
    common = [e for e in dict.fromkeys(t_old) if e in s_new]
    idx_new = {e: i for i, e in enumerate(t_new) if e in s_new}
    seq_new = [idx_new[e] for e in common if e in idx_new]
    if seq_new != sorted(seq_new):
        # find the first inversion and name it
        for a in range(len(seq_new)):
            for b in range(a + 1, len(seq_new)):
                if seq_new[a] > seq_new[b]:
                    order_problems.append(f"'{common[a]}' now comes AFTER '{common[b]}'")
                    break
            if order_problems:
                break
    print(f"\n=== {label}")
    print(f"  events: {len(t_old)} old, {len(t_new)} new")
    print(f"  LOST (present in the original, gone now): {lost if lost else 'none'}")
    print(f"  ADDED (new behaviour):                   {added if added else 'none'}")
    print(f"  ORDER:  {'REORDERED -- ' + order_problems[0] if order_problems else 'preserved'}")
    return lost, order_problems


if __name__ == '__main__':
    old_path, new_path, *names = sys.argv[1:]
    old_text = open(old_path, encoding='utf-8').read()
    new_text = open(new_path, encoding='utf-8').read()
    problems = 0
    for name in names:
        olds = find_function(old_text, name)
        news = find_function(new_text, name)
        if not olds or not news:
            print(f"\n=== {name}: NOT FOUND (old={len(olds)}, new={len(news)})")
            continue
        lost, order = compare(olds[-1], news[-1], name)
        problems += len(lost) + len(order)
    print(f"\n{'*** ' + str(problems) + ' PROBLEM(S)' if problems else 'no lost events, no reordering'}")

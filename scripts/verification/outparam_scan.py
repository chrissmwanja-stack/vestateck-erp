"""Find bare references to RETURNS TABLE output names inside the function that declares them.

Usage:
    python3 scripts/verification/outparam_scan.py [file.sql ...]   (default: supabase/migrations/2026*.sql)

Measured on PostgreSQL 15 (live probe), not assumed:
  * bare name in a SELECT list of `return query select ...`  -> 42702, raises
  * bare name in a WHERE clause                             -> 42702, raises
  * bare name in ORDER BY                                   -> resolves to the OUT column, fine

This only flags plpgsql bodies. sql-language bodies have no OUT-variable ambiguity in the
same way, and are skipped rather than reported as clean.
"""
import re, sys, glob

def functions(text):
    out = []
    for m in re.finditer(r'create\s+(?:or\s+replace\s+)?function\s+([\w.]+)\s*\(', text, re.I):
        name = m.group(1)
        # returns table(...) ?
        head_end = text.find('as $', m.start())
        if head_end < 0:
            continue
        head = text[m.start():head_end]
        rt = re.search(r'returns\s+table\s*\((.*?)\)\s*\n\s*language', head, re.I | re.S)
        if not rt:
            continue
        params = set()
        for p in rt.group(1).split(','):
            p = p.strip()
            if not p:
                continue
            tok = re.split(r'\s+', p)
            params.add(tok[0].lower())
        # body
        bstart = text.find('$$', head_end)
        bend = text.find('$$;', bstart + 2)
        if bstart < 0 or bend < 0:
            continue
        body = text[bstart + 2:bend]
        lang = re.search(r'language\s+(\w+)', head, re.I)
        out.append((name, params, body, (lang.group(1).lower() if lang else '?')))
    return out

def strip_comments(s):
    return re.sub(r'--[^\n]*', '', s)

def strip_strings(s):
    return re.sub(r"'(?:[^']|'')*'", "''", s)

def scan(path):
    text = open(path, encoding='utf-8').read()
    hits = []
    for name, params, body, lang in functions(text):
        if lang != 'plpgsql':
            continue
        b = strip_strings(strip_comments(body)).lower()
        for p in params:
            for m in re.finditer(r'(?<![.\w])' + re.escape(p) + r'(?![\w])', b):
                line_start = b.rfind('\n', 0, m.start()) + 1
                line = b[line_start:b.find('\n', m.start()) if b.find('\n', m.start()) > 0 else len(b)]
                hits.append((name, p, line.strip()[:120]))
    return hits

paths = sys.argv[1:] or sorted(glob.glob('supabase/migrations/2026*.sql'))
for f in paths:
    hits = scan(f)
    if hits:
        print(f"\n=== {f.split('/')[-1]}")
        for name, p, line in hits:
            print(f"  [{p}] in {name.split('.')[-1]}: {line}")

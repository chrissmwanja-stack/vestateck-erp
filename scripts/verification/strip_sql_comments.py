"""Remove -- comments from SQL without touching string literals or dollar-quoted bodies.

Runs in one transaction, so it must not alter semantics: comments are inert, but a naive
"remove everything after --" mangles any literal containing it (there is a '$q$' helper in
the tests, and descriptions with ' -- ' are possible).
"""
import sys


def strip(sql):
    out = []
    i, n = 0, len(sql)
    in_s = None          # ' or "
    in_dollar = None     # the $tag$ currently open
    while i < n:
        c = sql[i]
        if in_dollar is not None:
            if sql.startswith(in_dollar, i):
                out.append(in_dollar); i += len(in_dollar); in_dollar = None; continue
            out.append(c); i += 1; continue
        if in_s is not None:
            if c == in_s:
                if i + 1 < n and sql[i + 1] == in_s:      # doubled quote
                    out.append(c + c); i += 2; continue
                in_s = None
            out.append(c); i += 1; continue
        if c == '-' and i + 1 < n and sql[i + 1] == '-':
            j = sql.find('\n', i)
            i = n if j < 0 else j                            # drop to end of line, keep newline
            continue
        if c == "'" or c == '"':
            in_s = c; out.append(c); i += 1; continue
        if c == '$':
            j = i + 1
            while j < n and (sql[j].isalnum() or sql[j] == '_'):
                j += 1
            if j < n and sql[j] == '$':
                in_dollar = sql[i:j + 1]
                out.append(in_dollar); i = j + 1; continue
        out.append(c); i += 1
    # collapse the blank lines the comment removal leaves behind
    lines = [ln for ln in ''.join(out).split('\n')]
    kept, blank = [], 0
    for ln in lines:
        if ln.strip() == '':
            blank += 1
            if blank > 1:
                continue
        else:
            blank = 0
        kept.append(ln)
    return '\n'.join(kept)


if __name__ == '__main__':
    src = open(sys.argv[1], encoding='utf-8').read()
    res = strip(src)
    if len(sys.argv) > 2:
        open(sys.argv[2], 'w', encoding='utf-8').write(res)
    sys.stderr.write(f"{sys.argv[1]}: {len(src)} -> {len(res)} bytes\n")

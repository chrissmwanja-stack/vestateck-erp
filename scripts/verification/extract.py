"""Pull one SQL object out of a migration file, exactly as written.

The terminator search matters: a plpgsql body ends 'end $$;' (no newline before $$),
so searching for a newline-preceded '$$;' runs past the object and swallows the next
one. That produced a false "this function is fine" reading once already.
"""
import sys


def extract(path, start_marker):
    s = open(path, encoding='utf-8').read()
    i = s.find(start_marker)
    if i < 0:
        return None
    j = s.find('$$;', i)
    if j < 0:
        return None
    return s[i:j + 3]


if __name__ == '__main__':
    got = extract(sys.argv[1], sys.argv[2])
    sys.stdout.write(got if got else 'NOT FOUND')

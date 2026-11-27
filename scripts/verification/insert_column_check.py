"""Check that every INSERT column list in a test exists in the live schema.

Written after finding two such errors in a committed end-to-end test that had never been
executed: it inserted `currency` into ins_commission_entries, which has never had that
column, and it created a bound policy with status 'active' while leaving bound_at null,
which violates ins_policies_bound_check. Both would have failed at the file's own fixture,
before a single control was exercised.

Those two were found by hand, by trying to run the file. This makes the mechanical part
repeatable: a column name typo is invisible to a parser, because PostgreSQL resolves
identifiers in an INSERT column list only when the statement runs.

Usage:
    python3 scripts/verification/insert_column_check.py <test.sql> [<test.sql> ...]

Reads docs/insurance-brokerage/schema-columns.snapshot.json. Refresh that snapshot when the
schema changes:

    select table_name || '|' || string_agg(column_name, ',' order by ordinal_position)
      from information_schema.columns where table_schema='public' group by table_name;

It checks column names only. It cannot see NOT NULL columns you forgot to supply, CHECK
constraints you violate, or triggers that refuse the row -- all three of which bit the same
file. Treat a clean run as "no typos", not as "this fixture works".
"""
import re, sys, json, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SNAPSHOT = os.path.join(ROOT, 'docs', 'insurance-brokerage', 'schema-columns.snapshot.json')

TABLES = {k: set(v.split(',')) for k, v in json.load(open(SNAPSHOT)).items()}
bad = 0
for path in sys.argv[1:]:
    src = open(path, encoding='utf-8').read()
    for m in re.finditer(r'insert\s+into\s+(?:public\.)?(\w+)\s*\(([^()]*)\)', src, re.I | re.S):
        table = m.group(1)
        if table not in TABLES:
            continue
        cols = [c.strip() for c in m.group(2).replace('\n', ' ').split(',')]
        missing = [c for c in cols if re.fullmatch(r'[a-z_][a-z0-9_]*', c) and c not in TABLES[table]]
        if missing:
            bad += 1
            print(f"  {os.path.basename(path)}: insert into {table} -> NOT A COLUMN: {missing}")
print('OK - every INSERT column exists in the live schema' if not bad else f'{bad} problem(s)')
sys.exit(1 if bad else 0)

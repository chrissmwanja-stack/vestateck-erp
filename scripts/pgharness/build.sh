#!/usr/bin/env bash
# =====================================================================
# Rebuild a local PostgreSQL that this repo's migrations and SQL tests can
# be replayed against (no Supabase stack, no Docker).
#
#   scripts/pgharness/build.sh                 # install if needed, start, db "harness"
#   scripts/pgharness/build.sh mydb            # same, into database "mydb"
#   scripts/pgharness/build.sh mydb --no-migrations   # baseline only
#   scripts/pgharness/build.sh mydb --seed            # ... and apply supabase/seed.sql
#                                                     # (dev fixtures: two tests need it)
#
# With --seed the whole SQL suite passes (112/112 at the time of writing):
#   psql -h /tmp/pgsock -p 5433 -U postgres -d mydb -v ON_ERROR_STOP=1 \
#        -f supabase/tests/test_ins_import_client_money_bank.sql
#
# Everything ephemeral lives in /tmp (cluster, baseline dump); only this
# script and prelude.sql are kept in the repo workspace, because .local/ and
# node_modules/ are not captured in snapshots.
# =====================================================================
set -euo pipefail

DB="${1:-harness}"
SHIFT_MIGRATIONS="${2:-}"
WITH_SEED="${3:-${SEED:-}}"
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -d "$REPO/supabase/migrations" ] || REPO=/home/user/vestateck-erp
PGBIN="${PGBIN:-/usr/lib/postgresql/17/bin}"
PGDATA="/tmp/pgdata"
PGSOCK="/tmp/pgsock"
PGPORT="5433"

# 1. server binaries (apt, not snapshotted)
if [ ! -x "$PGBIN/psql" ]; then
  echo "== installing postgresql-17"
  sudo apt-get update -qq >/dev/null 2>&1 || apt-get update -qq >/dev/null 2>&1
  sudo apt-get install -y -qq postgresql-17 postgresql-contrib-17 >/tmp/pg-install.log 2>&1 \
    || apt-get install -y -qq postgresql-17 postgresql-contrib-17 >/tmp/pg-install.log 2>&1
fi

# 2. cluster
if [ ! -d "$PGDATA" ]; then
  echo "== initdb"
  mkdir -p "$PGSOCK"
  chmod 700 "$PGSOCK"
  "$PGBIN/initdb" -D "$PGDATA" -U postgres --auth=trust >/dev/null
fi
if ! "$PGBIN/pg_isready" -h "$PGSOCK" -p "$PGPORT" -q; then
  echo "== starting"
  "$PGBIN/pg_ctl" -D "$PGDATA" -l /tmp/pg.log \
    -o "-k $PGSOCK -p $PGPORT -c listen_addresses=''" start >/dev/null
  for _ in $(seq 1 30); do
    "$PGBIN/pg_isready" -h "$PGSOCK" -p "$PGPORT" -q && break
    sleep 0.5
  done
fi
PSQL=("$PGBIN/psql" -h "$PGSOCK" -p "$PGPORT" -U postgres -v ON_ERROR_STOP=1 -q)

# 3. database
"$PGBIN/dropdb" -h "$PGSOCK" -p "$PGPORT" -U postgres --if-exists "$DB" >/dev/null 2>&1 || true
"$PGBIN/createdb" -h "$PGSOCK" -p "$PGPORT" -U postgres "$DB"
echo "== prelude"
"${PSQL[@]}" -d "$DB" -f "$(dirname "${BASH_SOURCE[0]}")/prelude.sql" >/dev/null

# 4. the squashed baseline, minus the extensions this cluster cannot install
BASE="$REPO/supabase/migrations/20261031235900_squashed_baseline.sql"
# only the CREATE EXTENSION lines: pg_cron is also referenced inside a
# function body, which must stay.
grep -viE '^create extension .*(pg_cron|pg_stat_statements)' "$BASE" > /tmp/baseline.sql
echo "== baseline"
"${PSQL[@]}" -d "$DB" -f /tmp/baseline.sql >/dev/null

# 5. the November tail, in name order
if [ "$SHIFT_MIGRATIONS" != "--no-migrations" ]; then
  echo "== migrations"
  for f in $(ls "$REPO"/supabase/migrations/202611*.sql | sort); do
    if ! "${PSQL[@]}" -d "$DB" -f "$f" >/tmp/mig.log 2>&1; then
      echo "   FAILED: $(basename "$f")"; grep -m3 ERROR /tmp/mig.log; exit 1
    fi
  done
fi

# 6. optional dev fixtures
if [ "$SHIFT_MIGRATIONS" = "--seed" ] || [ "$WITH_SEED" = "--seed" ]; then
  echo "== seed"
  if ! "${PSQL[@]}" -d "$DB" -f "$REPO/supabase/seed.sql" >/tmp/seed.log 2>&1; then
    echo "   FAILED: seed.sql"; grep -m3 ERROR /tmp/seed.log; exit 1
  fi
fi

echo "== ready: database $DB on $PGSOCK:$PGPORT"
echo "   psql -h $PGSOCK -p $PGPORT -U postgres -d $DB -f supabase/tests/<test>.sql"

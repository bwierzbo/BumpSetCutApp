#!/bin/zsh
# Runs migration 048 against a throwaway local PostgreSQL cluster with Supabase stand-ins, then its tests.
# Nothing touches the live project. Usage: supabase/tests/run_048_tests.sh  (needs a local PostgreSQL ≥ 14)
set -euo pipefail
here=${0:A:h}
setopt null_glob; bin=${PG_BIN:-$(ls -d /usr/local/opt/postgresql@*/bin /opt/homebrew/opt/postgresql@*/bin 2>/dev/null | tail -1)}
[[ -x $bin/initdb ]] || { echo "no local PostgreSQL (set PG_BIN)"; exit 2; }
tmp=$(mktemp -d)
trap '"$bin/pg_ctl" -D "$tmp/db" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
"$bin/initdb" -D "$tmp/db" -U postgres -A trust >/dev/null
"$bin/pg_ctl" -D "$tmp/db" -o "-k $tmp -c listen_addresses='' -p 55448" -l "$tmp/log" -w start >/dev/null
psql() { "$bin/psql" -h "$tmp" -p 55448 -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
psql -f "$here/048_stubs.sql"
psql -f "${MIGRATION_048:-$here/../migrations/048_label_rally_events.sql}"
psql -At -f "$here/048_tests.sql" | grep -v '^$' | tail -1
# 050 (the published pilot draw) on a fresh database of the same cluster: stubs, 048, 050, its tests.
[[ -f "$here/../migrations/050_label_pilot.sql" ]] || exit 0
psql -c "CREATE DATABASE t050" >/dev/null
psql50() { "$bin/psql" -h "$tmp" -p 55448 -U postgres -d t050 -v ON_ERROR_STOP=1 -q "$@"; }
psql50 -f "$here/048_stubs.sql"
psql50 -f "$here/../migrations/048_label_rally_events.sql"
psql50 -f "$here/../migrations/050_label_pilot.sql"
psql50 -At -f "$here/050_pilot_tests.sql" | grep -v '^$' | tail -1

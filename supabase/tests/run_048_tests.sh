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

# 049_protect_withheld_footage on another fresh database: stubs (live-equivalent prior policies), 048, the fix.
if [[ -f "$here/../migrations/049_protect_withheld_footage.sql" ]]; then
    psql -c "CREATE DATABASE tprotect" >/dev/null
    psqlp() { "$bin/psql" -h "$tmp" -p 55448 -U postgres -d tprotect -v ON_ERROR_STOP=1 -q "$@"; }
    psqlp -f "$here/048_stubs.sql"
    psqlp -f "$here/../migrations/048_label_rally_events.sql"
    psqlp -f "${MIGRATION_049P:-$here/../migrations/049_protect_withheld_footage.sql}"
    psqlp -At -f "$here/049_protect_tests.sql" | grep -v '^$' | tail -1
fi

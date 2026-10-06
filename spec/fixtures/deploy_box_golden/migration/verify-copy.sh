#!/bin/bash
# Compare two databases holding widget-shop's schemas (structure and exact row counts of every table)
# through a bastion that can reach both. Read-only on both. Used at the end of restore-to-rds.sh, for a
# backup restore drill (production vs a database restored from its backup) and for checking a rollback copy.
#
#   verify-copy.sh <bastion-instance-id> <host-a> <secret-arn-a> <host-b> <secret-arn-b>
#
#   A_DB, B_DB   the database on each side (default widgetdb)
#
# Schemas compared: widgets widgets_cms
# Exit 0 only if both are identical and no materialized view is unpopulated in either; 50 when they differ.
set -euo pipefail

BASTION=${1:?bastion instance id}; A_HOST=${2:?}; A_SECRET=${3:?}; B_HOST=${4:?}; B_SECRET=${5:?}
SCHEMAS="widgets,widgets_cms"
A_DB=${A_DB:-widgetdb}; B_DB=${B_DB:-widgetdb}
A_PORT=15434; B_PORT=15435

pg_major() { "$1" --version 2>/dev/null | sed -E 's/.* ([0-9]+)[.].*/\1/'; }
if [ "$(pg_major psql || echo 0)" -lt 16 ] && [ -x /opt/homebrew/opt/postgresql@16/bin/psql ]; then
  export PATH=/opt/homebrew/opt/postgresql@16/bin:$PATH
fi

WORK=$(mktemp -d); PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT

secret_field() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text | jq -r "$2"; }
A_PW=$(secret_field "$A_SECRET" .password); B_PW=$(secret_field "$B_SECRET" .password)
A_USER=$(secret_field "$A_SECRET" '.username // "postgres"'); B_USER=$(secret_field "$B_SECRET" '.username // "postgres"')
tunnel() {
  aws ssm start-session --target "$BASTION" --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$1\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$2\"]}" >"$WORK/t_$2.log" 2>&1 &
  PIDS+=($!); disown
}
tunnel "$A_HOST" $A_PORT; tunnel "$B_HOST" $B_PORT
for i in $(seq 1 20); do
  grep -q "Waiting for connections" "$WORK/t_$A_PORT.log" 2>/dev/null && grep -q "Waiting for connections" "$WORK/t_$B_PORT.log" 2>/dev/null && break
  sleep 1
done
A() { PGPASSWORD=$A_PW psql -h localhost -p $A_PORT -U "$A_USER" -d "$A_DB" -Atc "$1"; }
B() { PGPASSWORD=$B_PW psql -h localhost -p $B_PORT -U "$B_USER" -d "$B_DB" -Atc "$1"; }

SHAPE="select n.nspname||' '||c.relkind::text, count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname = any(string_to_array('$SCHEMAS', ',')) group by 1
 union all select 'policies', count(*) from pg_policies where schemaname = any(string_to_array('$SCHEMAS', ','))
 union all select 'functions', count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname = any(string_to_array('$SCHEMAS', ',')) order by 1"
COUNTS="select table_schema||'.'||table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_type='BASE TABLE' and table_schema = any(string_to_array('$SCHEMAS', ',')) order by 1"
UNPOP="select count(*) from pg_matviews where schemaname = any(string_to_array('$SCHEMAS', ',')) and not ispopulated"

BAD=0
A "$SHAPE" >"$WORK/shape_a"; B "$SHAPE" >"$WORK/shape_b"
A "$COUNTS" >"$WORK/counts_a"; B "$COUNTS" >"$WORK/counts_b"
[ -s "$WORK/counts_a" ] || { echo "FAIL: first database has no tables to compare" >&2; BAD=1; }
[ "$(A "$UNPOP")" = 0 ] && [ "$(B "$UNPOP")" = 0 ] || { echo "FAIL: unpopulated materialized views" >&2; BAD=1; }
diff "$WORK/shape_a" "$WORK/shape_b" >/dev/null || { echo "FAIL: structure differs" >&2; diff "$WORK/shape_a" "$WORK/shape_b" >&2 || true; BAD=1; }
diff "$WORK/counts_a" "$WORK/counts_b" >/dev/null || { echo "FAIL: row counts differ" >&2; diff "$WORK/counts_a" "$WORK/counts_b" >&2 || true; BAD=1; }
[ "$BAD" = 0 ] || exit 50
echo "OK: $(wc -l <"$WORK/counts_a" | tr -d ' ') tables, identical row counts and structure"

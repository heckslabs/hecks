#!/bin/bash
# Copy widget-shop's schemas from the old database into the new RDS instance through a bastion that can
# reach both, then verify the copy. Piped dump | restore, so nothing is written to disk. Never writes to
# the source.
#
#   restore-to-rds.sh <bastion-instance-id> <source-host> <source-secret-arn> <rds-host> <rds-secret-arn>
#
#   FORCE=1   drop the target schemas first: a re-load before cutover, or a rollback copy in the other
#             direction (swap the hosts and secrets, and SRC_DB and DST_DB)
#   SRC_DB    the source database (default legacy)
#   DST_DB    the target database (default widgetdb)
#
# Schemas copied: widgets widgets_cms
#
# Why not a plain pg_restore: a Hecks schema's materialized views call hecks_tr_extract() unqualified, and
# pg_restore runs with an empty search_path, so the restore's REFRESH step errors on them. This restores
# tolerating exactly that error, then refreshes the views with the schema on the search_path, and fails on
# any other error.
#
# Needs pg_dump, pg_restore and psql 16 or newer, the SSM plugin, jq and AWS credentials that can read both
# secrets and start SSM sessions.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

BASTION=${1:?bastion instance id}; SRC_HOST=${2:?source host}; SRC_SECRET=${3:?source secret arn}
DST_HOST=${4:?target host}; DST_SECRET=${5:?target secret arn}
SCHEMAS="widgets widgets_cms"
SRC_DB=${SRC_DB:-legacy}; DST_DB=${DST_DB:-widgetdb}
SRC_PORT=15432; DST_PORT=15433

pg_major() { "$1" --version 2>/dev/null | sed -E 's/.* ([0-9]+)[.].*/\1/'; }
# The default client on the PATH is often older than the server (Homebrew's is 14); prefer postgresql@16.
if [ "$(pg_major pg_dump || echo 0)" -lt 16 ] && [ -x /opt/homebrew/opt/postgresql@16/bin/pg_dump ]; then
  export PATH=/opt/homebrew/opt/postgresql@16/bin:$PATH
fi
for t in pg_dump pg_restore psql; do
  [ "$(pg_major $t || echo 0)" -ge 16 ] || { echo "need $t 16 or newer on the PATH" >&2; exit 1; }
done

WORK=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT

secret_field() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text | jq -r "$2"; }
SRC_PW=$(secret_field "$SRC_SECRET" .password); DST_PW=$(secret_field "$DST_SECRET" .password)
SRC_USER=$(secret_field "$SRC_SECRET" '.username // "postgres"'); DST_USER=$(secret_field "$DST_SECRET" '.username // "postgres"')

tunnel() { # host local-port
  aws ssm start-session --target "$BASTION" --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$1\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$2\"]}" >"$WORK/tunnel_$2.log" 2>&1 &
  PIDS+=($!)
  disown # so shutting the tunnel down at exit does not print a "Terminated" line
}
tunnel "$SRC_HOST" $SRC_PORT; tunnel "$DST_HOST" $DST_PORT
for i in $(seq 1 20); do
  grep -q "Waiting for connections" "$WORK/tunnel_$SRC_PORT.log" 2>/dev/null && grep -q "Waiting for connections" "$WORK/tunnel_$DST_PORT.log" 2>/dev/null && break
  sleep 1
done

SRC() { PGPASSWORD=$SRC_PW psql -h localhost -p $SRC_PORT -U "$SRC_USER" -d "$SRC_DB" -Atc "$1"; }
DST() { PGPASSWORD=$DST_PW psql -h localhost -p $DST_PORT -U "$DST_USER" -d "$DST_DB" -Atc "$1"; }
echo "source $(SRC 'show server_version'), target $(DST 'show server_version')"

# Refuse to clobber a target that already holds the schemas.
for S in $SCHEMAS; do
  if [ "$(DST "select count(*) from pg_namespace where nspname='$S'")" != 0 ]; then
    if [ "${FORCE:-}" = 1 ]; then DST "drop schema \"$S\" cascade" >/dev/null; echo "dropped target schema $S"
    else echo "target already has schema $S; re-run with FORCE=1 to replace it" >&2; exit 1; fi
  fi
done

for S in $SCHEMAS; do
  echo "== copying schema $S"
  PGPASSWORD=$SRC_PW pg_dump -h localhost -p $SRC_PORT -U "$SRC_USER" -d "$SRC_DB" --schema="$S" -Fc --no-owner --no-privileges \
    | PGPASSWORD=$DST_PW pg_restore -h localhost -p $DST_PORT -U "$DST_USER" -d "$DST_DB" --no-owner --no-privileges 2>"$WORK/err_$S.txt" || true
  TOTAL=$(grep -c 'error:' "$WORK/err_$S.txt" || true)
  UNEXPECTED=$(grep 'error:' "$WORK/err_$S.txt" | grep -vc 'hecks_tr_extract' || true)
  echo "   restore errors: $TOTAL (unexpected: $UNEXPECTED)"
  if [ "$UNEXPECTED" != 0 ]; then grep 'error:' "$WORK/err_$S.txt" | grep -v 'hecks_tr_extract' | head -5 >&2; exit 1; fi
done

# Refresh what pg_restore could not (with the schema on the search_path).
for S in $SCHEMAS; do
  for MV in $(DST "select matviewname from pg_matviews where schemaname='$S' and not ispopulated"); do
    PGPASSWORD=$DST_PW psql -h localhost -p $DST_PORT -U "$DST_USER" -d "$DST_DB" -qAtc "set search_path=\"$S\",public; refresh materialized view \"$S\".\"$MV\""
  done
done

# Same structure, same exact row counts in every table, nothing unpopulated.
A_DB=$SRC_DB B_DB=$DST_DB bash "$HERE/verify-copy.sh" "$BASTION" "$SRC_HOST" "$SRC_SECRET" "$DST_HOST" "$DST_SECRET"

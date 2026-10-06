#!/bin/bash
# Create scratch-fixture's database and login role on the shared RDS instance (stack hecks-platform-rds), and the
# secret scratch-fixture/database that the box's containers read. Run once for a new site, from a machine with
# AWS credentials that may read the instance's master secret and start SSM sessions, through a bastion
# that can reach the instance.
#
#   provision-database.sh <bastion-instance-id> [--rotate]
#
# The role owns only the database scratch, is not a superuser, and no other role may connect to that
# database. The secret holds {username, password, host, port, dbname}; the box's role reads that secret
# and never the instance's master secret.
#
# Safe to run again: a role and a database that exist are left alone, and a secret that exists keeps
# its password. --rotate gives the role a new password and writes it to the secret; roll the box after it.
#
# Ends 70 (the shared stack has no instance).
#
# Needs psql, jq, openssl, the SSM plugin and AWS credentials.
set -euo pipefail

BASTION=${1:?bastion instance id}
ROTATE=${2:-}
[ -z "$ROTATE" ] || [ "$ROTATE" = --rotate ] || { echo "usage: provision-database.sh <bastion-instance-id> [--rotate]" >&2; exit 2; }
RDS_STACK=hecks-platform-rds
DB=scratch
ROLE=scratch
SECRET=scratch-fixture/database
PORT=15434
out() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey==\`$2\`].OutputValue" --output text; }

HOST=$(out "$RDS_STACK" DbEndpoint)
MASTER=$(out "$RDS_STACK" DbSecretArn)
[ -n "$HOST" ] && [ "$HOST" != None ] || { echo "no instance in stack $RDS_STACK" >&2; exit 70; }

WORK=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT

master_field() { aws secretsmanager get-secret-value --secret-id "$MASTER" --query SecretString --output text | jq -r "$1"; }
MASTER_USER=$(master_field '.username // "postgres"')
MASTER_PW=$(master_field .password)

aws ssm start-session --target "$BASTION" --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$HOST\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$PORT\"]}" >"$WORK/tunnel.log" 2>&1 &
PIDS+=($!)
disown
for _ in $(seq 1 20); do grep -q "Waiting for connections" "$WORK/tunnel.log" 2>/dev/null && break; sleep 1; done

# One statement, one answer. The master connects to the maintenance database.
M() { PGPASSWORD=$MASTER_PW psql -h localhost -p $PORT -U "$MASTER_USER" -d postgres -v ON_ERROR_STOP=1 -Atc "$1"; }
# A script on stdin, with the new password passed as a variable so it is never in a command line.
MS() { PGPASSWORD=$MASTER_PW psql -h localhost -p $PORT -U "$MASTER_USER" -d postgres -v ON_ERROR_STOP=1 -v pw="$PW" -q -f -; }

HAVE_ROLE=$(M "select count(*) from pg_roles where rolname='$ROLE'")
HAVE_SECRET=no
aws secretsmanager describe-secret --secret-id "$SECRET" >/dev/null 2>&1 && HAVE_SECRET=yes

# Letters and digits only: the host puts the password in a URL without percent-encoding it.
PW=""
if [ "$HAVE_ROLE" = 0 ]; then
  PW=$(openssl rand -hex 16)
  MS <<SQL
create role "$ROLE" login password :'pw' nosuperuser nocreatedb nocreaterole noinherit;
SQL
  echo "created role $ROLE"
elif [ "$ROTATE" = --rotate ] || [ "$HAVE_SECRET" = no ]; then
  PW=$(openssl rand -hex 16)
  MS <<SQL
alter role "$ROLE" password :'pw';
SQL
  echo "set a new password for role $ROLE"
else
  echo "role $ROLE exists and so does $SECRET; kept"
fi

# RDS's master is not a true superuser: it may create a database for a role only as a member of that role.
if [ "$(M "select count(*) from pg_database where datname='$DB'")" = 0 ]; then
  M "grant \"$ROLE\" to \"$MASTER_USER\"" >/dev/null
  M "create database \"$DB\" owner \"$ROLE\"" >/dev/null
  echo "created database $DB"
else
  echo "database $DB exists"
fi
# Nobody but the owner (and the master) may connect to it.
M "revoke all on database \"$DB\" from public" >/dev/null

if [ -n "$PW" ]; then
  BODY=$(jq -n --arg u "$ROLE" --arg p "$PW" --arg h "$HOST" --arg d "$DB" '{username: $u, password: $p, host: $h, port: 5432, dbname: $d}')
  if [ "$HAVE_SECRET" = yes ]; then
    aws secretsmanager put-secret-value --secret-id "$SECRET" --secret-string "$BODY" >/dev/null
  else
    aws secretsmanager create-secret --name "$SECRET" --description "scratch-fixture's database login on hecks-platform-rds" --secret-string "$BODY" >/dev/null
  fi
  echo "wrote secret $SECRET"
fi
echo "ok   $DB on $HOST, role $ROLE, secret $SECRET"

#!/bin/bash
# Roll widget-shop's app box: render the compose files, push them over SSM, start the containers and check
# them. Exits non-zero if the roll fails or the box does not answer as expected.
#
#   deploy-box.sh [name=tag ...]
#
# A container named without a tag runs its "latest" image. Secret values are resolved on the box by
# fetch-secrets.sh and never pass through the SSM command.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BOX_STACK=hecks-widget-shop-box
RDS_STACK=hecks-widget-shop-rds
REGION=us-east-1
DIR=/opt/widget-shop
out() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey==\`$2\`].OutputValue" --output text; }

BOX=$(out "$BOX_STACK" InstanceId)
DB_HOST=$(out "$RDS_STACK" DbEndpoint)
DB_SECRET=$(out "$RDS_STACK" DbSecretArn)
[ -n "$BOX" ] && [ "$BOX" != None ] || { echo "no instance in stack $BOX_STACK" >&2; exit 1; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && bash "$HERE/render-compose.sh" "$DB_HOST" "$DB_SECRET" "$@" )

# Run a script on the box over SSM, wait for it, print its output, return its status.
run_on_box() {
  local cid st i
  cid=$(aws ssm send-command --instance-ids "$BOX" --document-name AWS-RunShellScript --timeout-seconds 900 \
    --parameters "$1" --query 'Command.CommandId' --output text)
  sleep 3
  for i in $(seq 1 150); do
    st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$BOX" --query Status --output text)
    [ "$st" != InProgress ] && [ "$st" != Pending ] && break
    sleep 5
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$BOX" --query StandardOutputContent --output text
  [ "$st" = Success ]
}

B64() { base64 < "$1" | tr -d '\n'; }
ROLL=$(jq -n --arg compose "$(B64 "$WORK/compose.json")" --arg secrets "$(B64 "$WORK/secrets.json")" \
  --arg caddy "$(B64 "$HERE/Caddyfile")" --arg fetch "$(B64 "$HERE/fetch-secrets.sh")" \
  --arg registry "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com" --arg dir "$DIR" '
  {commands: ["cloud-init status --wait >/dev/null 2>&1 || true",
    "set -e", "mkdir -p \($dir)/caddy-extra && cd \($dir)", "umask 077",
    "echo \($compose) | base64 -d > compose.json; echo \($secrets) | base64 -d > secrets.json",
    "echo \($caddy) | base64 -d > Caddyfile; echo \($fetch) | base64 -d > fetch-secrets.sh",
    "bash fetch-secrets.sh",
    "aws ecr get-login-password --region '"$REGION"' | docker login --username AWS --password-stdin \($registry) >/dev/null",
    "docker compose -f compose.json pull --quiet",
    "docker compose -f compose.json up -d --remove-orphans",
    "sleep 20; docker compose -f compose.json ps --format \"table {{.Service}}\\t{{.Status}}\""],
   executionTimeout: ["900"]}')

echo "==> rolling $BOX_STACK ($BOX) at $(date -u +%H:%M:%SZ)"
run_on_box "$ROLL" || { echo "==> the roll did not succeed" >&2; exit 1; }

echo "==> checking the box"
CHECK=$(cat <<'CHECK_EOF'
cd /opt/widget-shop
BAD=0
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 40 localhost/)
[ "${code#5}" = "$code" ] && echo "ok   the proxy serves / -> $code" || { echo "FAIL the proxy serves / -> $code"; BAD=1; }
DOWN=$(docker compose -f compose.json ps --format "{{.Service}} {{.Status}}" | grep -vE " Up " || true)
if [ -z "$DOWN" ]; then echo "ok   every container is up"; else echo "FAIL containers not up: $DOWN"; BAD=1; fi
[ "$BAD" = 0 ]
CHECK_EOF
)
CHECK_JSON=$(jq -n --arg c "$(printf '%s' "$CHECK" | base64 | tr -d '\n')" '{commands: ["echo \($c) | base64 -d | bash"]}')
run_on_box "$CHECK_JSON" || { echo "==> the box is NOT healthy after the roll" >&2; exit 1; }
echo "==> box roll done ($(date -u +%H:%M:%SZ))"

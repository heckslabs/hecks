#!/bin/bash
# Render compose.json and secrets.json for widget-shop's app box from an ECS task definition.
#
#   render-compose.sh <db-host> <db-secret-arn> [task-definition]
#
# The task definition (a family or family:revision; default: the latest active revision of widget-platform)
# is the source of truth for each container's image, environment and secrets, so the box starts with
# what the task would have. A container the box runs must be named in it. DB_HOST and DB_SECRET_ARN
# are replaced with the RDS stack's values where the task defines them, and every container runs on
# the box's own network, so the proxy reaches each one on 127.0.0.1:<port>. Secrets (name + valueFrom)
# are written to secrets.json for fetch-secrets.sh to resolve on the box.
#
# When the world names origin_env, the named origin secret is compared with those variables in the
# task definition and the render refuses on any difference (Caddy checks the CDN's header against
# the secret; the containers check it against their own copy). Values are never printed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DB_HOST=${1:?rds endpoint}
DB_SECRET=${2:?rds secret arn}
TD=${3:-widget-platform}

DEF=$(aws ecs describe-task-definition --task-definition "$TD" --query 'taskDefinition.containerDefinitions' --output json)
echo "rendering from task definition $TD" >&2

ORIGIN_ENV=$(jq -r '.origin.env // [] | .[]' "$HERE/services.json")
if [ -n "$ORIGIN_ENV" ]; then
  ORIGIN_SECRET_ID=$(jq -r '.origin.secret' "$HERE/services.json")
  ORIGIN_VALUE=$(aws secretsmanager get-secret-value --secret-id "$ORIGIN_SECRET_ID" --query SecretString --output text)
  for NAME in $ORIGIN_ENV; do
    HOLDERS=$(echo "$DEF" | jq -r --arg n "$NAME" '[.[] | select(any((.environment // [])[]; .name == $n)) | .name] | join(" ")')
    [ -n "$HOLDERS" ] || { echo "refusing to render: origin_env names $NAME, which no container in $TD sets" >&2; exit 1; }
    DIFFERENT=$(echo "$DEF" | jq -r --arg n "$NAME" --arg v "$ORIGIN_VALUE" \
      '[.[] | select(any((.environment // [])[]; .name == $n and .value != $v)) | .name] | join(" ")')
    [ -z "$DIFFERENT" ] || { echo "refusing to render: $NAME in $TD (container: $DIFFERENT) differs from the origin secret $ORIGIN_SECRET_ID; the proxy would refuse every request from the CDN. Make them equal." >&2; exit 1; }
  done
fi

jq --argjson def "$DEF" --arg host "$DB_HOST" --arg secret "$DB_SECRET" '
  def log: {driver: "json-file", options: {"max-size": "10m", "max-file": "3"}};
  def env(c): ((c.environment // []) | map({(.name): .value}) | add // {})
    | (if has("DB_HOST") then .DB_HOST = $host | .DB_SECRET_ARN = $secret else . end);
  . as $in
  | {services: (
      ($in.services | with_entries(.value |= (. as $s
        | ($def | map(select(.name == $s.name)) | first) as $c
        | if $c == null then error("task definition has no container named " + $s.name) else
            {image: $c.image, network_mode: "host", restart: "unless-stopped", logging: log,
             environment: ({PORT: ($s.port | tostring)} + env($c))}
            + (if (($c.secrets // []) | length) > 0 then {env_file: [($s.name + ".secrets.env")]} else {} end)
          end)))
      + {caddy: ({image: "public.ecr.aws/docker/library/caddy:2.8@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f", network_mode: "host", restart: "unless-stopped",
                  volumes: ["./Caddyfile:/etc/caddy/Caddyfile:ro", "./caddy-extra:/etc/caddy/extra:ro"], logging: log}
                 + (if $in.origin then {env_file: ["caddy.secrets.env"]} else {} end))}
      + (if $in.tunnel then {cloudflared: {image: $in.tunnel.image, network_mode: "host", restart: "unless-stopped",
                  command: ["tunnel", "--no-autoupdate", "--url", $in.tunnel.url, "run"],
                  env_file: ["cloudflared.secrets.env"], logging: log}} else {} end))}' \
  "$HERE/services.json" > compose.json

jq --argjson def "$DEF" '. as $in
    | [ ($in.services | keys[]) as $n | $def[] | select(.name == $n) | (.secrets // [])[]
        | {service: $n, name: .name, valueFrom: .valueFrom} ]
      + [ (if $in.origin then {service: "caddy", name: "ORIGIN_SECRET", valueFrom: $in.origin.secret} else empty end),
          (if $in.tunnel then {service: "cloudflared", name: "TUNNEL_TOKEN", valueFrom: $in.tunnel.token_secret} else empty end) ]' \
  "$HERE/services.json" > secrets.json

echo "rendered compose.json and secrets.json ($(jq '.services | length' compose.json) services)"

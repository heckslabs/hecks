#!/bin/bash
# Render compose.json and secrets.json for scratch-fixture's app box from services.json.
#
#   render-compose.sh <db-host> <db-secret-arn> [name=tag ...]
#
# Tags default to "latest". Every container gets DB_HOST, DB_NAME, DB_SECRET_ARN and PORT, and runs on the
# box's own network, so the proxy reaches each one on 127.0.0.1:<port>. Secrets named in services.json
# are written to secrets.json for fetch-secrets.sh to resolve on the box.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DB_HOST=${1:?rds endpoint}
DB_SECRET=${2:?rds secret arn}
shift 2

REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
TAGS=$(printf '%s\n' "$@" | jq -R 'select(length > 0) | split("=") | {(.[0]): .[1]}' | jq -s 'add // {}')

jq --arg ecr "$ECR" --argjson tags "$TAGS" --arg host "$DB_HOST" --arg secret "$DB_SECRET" --arg db "scratch" '
  def log: {driver: "json-file", options: {"max-size": "10m", "max-file": "3"}};
  . as $in
  | {services: (
      ($in.services | with_entries(.value |= (
        {image: ($ecr + "/" + .repository + ":" + ($tags[.name] // "latest")),
         network_mode: "host", restart: "unless-stopped", logging: log,
         environment: ({PORT: (.port | tostring), DB_HOST: $host, DB_NAME: $db, DB_SECRET_ARN: $secret} + .env)}
        + (if (.secrets | length) > 0 then {env_file: [(.name + ".secrets.env")]} else {} end))))
      + {caddy: ({image: "public.ecr.aws/docker/library/caddy:2.8@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f", network_mode: "host", restart: "unless-stopped",
                  volumes: ["./Caddyfile:/etc/caddy/Caddyfile:ro", "./caddy-extra:/etc/caddy/extra:ro"], logging: log}
                 + (if $in.origin then {env_file: ["caddy.secrets.env"]} else {} end))}
      + (if $in.tunnel then {cloudflared: {image: $in.tunnel.image, network_mode: "host", restart: "unless-stopped",
                  command: ["tunnel", "--no-autoupdate", "--url", $in.tunnel.url, "run"],
                  env_file: ["cloudflared.secrets.env"], logging: log}} else {} end))}' \
  "$HERE/services.json" > compose.json

jq '. as $in
    | [ ($in.services[] | . as $v | ($v.secrets | to_entries[]) | {service: $v.name, name: .key, valueFrom: .value}),
        (if $in.origin then {service: "caddy", name: "ORIGIN_SECRET", valueFrom: $in.origin.secret} else empty end),
        (if $in.tunnel then {service: "cloudflared", name: "TUNNEL_TOKEN", valueFrom: $in.tunnel.token_secret} else empty end) ]' \
  "$HERE/services.json" > secrets.json

echo "rendered compose.json and secrets.json ($(jq '.services | length' compose.json) services)"

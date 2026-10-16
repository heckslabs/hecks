#!/bin/bash
# Runs ON the box. Resolves secrets.json into per-service env files that compose reads, using the
# instance role, so secret values never pass through SSM command text.
#
# secrets.json: [{"service":"web","name":"AUTH_SECRET","valueFrom":"myapp/auth"}]
# valueFrom is a secret name (its whole string is the value) or a full ARN, optionally with a JSON
# key (arn:...:secret:NAME:jsonkey::) to pick one field of a JSON secret.
set -eu
cd "$(dirname "$0")"
umask 077
rm -f ./*.secrets.env
jq -r '.[] | [.service, .name, .valueFrom] | @tsv' secrets.json | while IFS=$'\t' read -r svc name from; do
  case "$from" in
    arn:*) id=$(echo "$from" | cut -d: -f1-7); region=$(echo "$from" | cut -d: -f4); jkey=$(echo "$from" | cut -d: -f8) ;;
    *) id=$from; region=""; jkey="" ;;
  esac
  val=$(aws secretsmanager get-secret-value ${region:+--region "$region"} --secret-id "$id" --query SecretString --output text)
  if [ -n "$jkey" ]; then val=$(printf %s "$val" | jq -r --arg k "$jkey" '.[$k]'); fi
  [ -n "$val" ] && [ "$val" != null ] || { echo "empty secret for $svc/$name" >&2; exit 1; }
  printf '%s=%s\n' "$name" "$val" >> "$svc.secrets.env"
done

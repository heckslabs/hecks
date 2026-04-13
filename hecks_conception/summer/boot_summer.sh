#!/bin/bash
# Boot Summer — Winter's local conception organ
# Runs on port 8787 by default

DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="$(cd "$DIR/../.." && pwd)"

export SUMMER_MODEL="mlx-community/Qwen2.5-3B-Instruct-4bit"
export SUMMER_ADAPTER="${SUMMER_ADAPTER:-$DIR/adapter}"

echo "☀ Booting Summer..."
echo "  model: $SUMMER_MODEL"
echo "  adapter: $SUMMER_ADAPTER"
echo "  port: ${1:-8787}"

python3 "$DIR/serve.py" --port "${1:-8787}"

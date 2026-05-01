#!/bin/sh
# [antibody-exempt: thin shebang-redirector shim from old status.sh; dispatches to capabilities/status/status.bluebook via hecks-life run. Retires when the Unix `#!` convention is replaced by a `hecks` CLI multiplexer.]
DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve hecks-life binary : env first, sibling-repo target second,
# bare on PATH last. Without the fallbacks the bare `hecks-life` exec
# fails when this script runs in environments that don't have it on
# PATH (smoke-test sandboxes, CI runners, Claude Code subprocess envs).
HECKS="${HECKS_BIN:-}"
[ -z "$HECKS" ] && [ -x "$DIR/../rust/target/release/hecks-life" ] && \
  HECKS="$DIR/../rust/target/release/hecks-life"
[ -z "$HECKS" ] && HECKS="hecks-life"
exec "$HECKS" run "$DIR/capabilities/status/status.bluebook" "$@"

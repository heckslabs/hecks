#!/bin/sh
# [antibody-exempt: thin shebang-redirector shim from old status.sh; dispatches to capabilities/status/status.bluebook via hecks-life run. Retires when the Unix `#!` convention is replaced by a `hecks` CLI multiplexer.]
exec hecks-life run "$(cd "$(dirname "$0")" && pwd)/capabilities/status/status.bluebook" "$@"

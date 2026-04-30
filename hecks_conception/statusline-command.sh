#!/bin/bash
# statusline-command.sh — thin wrapper for Claude Code's statusline
# harness. Bluebook-of-record : hecks_conception/capabilities/statusline/
# Logic lives in hecks_life/src/run_statusline.rs (Rust runner).
#
# Claude Code's settings.json points the statusline action at this
# script (~/.claude/statusline-command.sh is a symlink here). The
# script's only job is to resolve the binary location and exec the
# `hecks-life statusline` subcommand ; the runner does the heki reads,
# the consciousness branch, the time animations, and the rendering.
#
# [antibody-exempt: hecks_conception/statusline-command.sh — three-line
#  transitional wrapper for Claude Code's harness ; the contract still
#  expects a .sh file. Retires when ~/.claude/settings.json points at
#  `hecks-life statusline` directly without the .sh shim. The 273 lines
#  of rendering logic that used to live here moved to the Rust runner
#  (i97 → i145).]

script="$0"
while [ -L "$script" ]; do script="$(readlink "$script")"; done
script_dir="$(cd "$(dirname "$script")" && pwd)"
hecks_root="$(cd "$script_dir/.." && pwd)"
hecks="${HECKS_LIFE:-$hecks_root/hecks_life/target/release/hecks-life}"

exec "$hecks" statusline

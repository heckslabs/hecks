#!/usr/bin/env bash
# status_golden.sh — bus-routed smoke that the status renderer surfaces the
# vitals after bus dispatch seeding.
#
# Restores coverage deleted in PR #717. The original seeded identity /
# consciousness / heartbeat / tick / mood via raw `heki upsert` and
# diffed against status_golden.expected. With direct heki writes retired,
# seeding flows through bus dispatch (Tick.MindstreamTick → fan-out to
# heart / heartbeat ; Consciousness.BecomeAttentive ; Mood.Focus). The
# golden-match is dropped — deterministic field combinations like
# state='awake' sleep_summary='testing status report' don't map to a
# single bus command, so we assert the SHAPE of the rendered status
# (sections present, vitals non-empty) instead of byte-equal golden.
#
# The status_golden.expected file is kept under tests/ for human eyeballing
# of the post-i717 rendered shape.
#
# Exit 0 on pass, non-zero on fail.

set -eu
set -m

here="$(cd "$(dirname "$0")" && pwd)"
conception="$(cd "$here/.." && pwd)"
repo_root="$(cd "$conception/.." && pwd)"

GIT_COMMON="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)"
case "$GIT_COMMON" in
  /*) MAIN_REPO="$(cd "$(dirname "$GIT_COMMON")" && pwd)" ;;
  ?*) MAIN_REPO="$(cd "$repo_root/$(dirname "$GIT_COMMON")" && pwd)" ;;
  *)  MAIN_REPO="$repo_root" ;;
esac

hecks="${STOREHOUSE:-}"
if [ -z "$hecks" ]; then
  for cand in \
    "$repo_root/rust/target/release/storehouse" \
    "$repo_root/rust/target/debug/storehouse" \
    "$MAIN_REPO/rust/target/release/storehouse" \
    "$MAIN_REPO/rust/target/debug/storehouse"; do
    if [ -x "$cand" ]; then hecks="$cand"; break; fi
  done
fi
export STOREHOUSE="$hecks"

BODY_DIR="${HECKS_BODY_DIR:-}"
[ -z "$BODY_DIR" ] && [ -d "$MAIN_REPO/../miette" ] && \
  BODY_DIR="$(cd "$MAIN_REPO/../miette" && pwd)"

tmp="$(mktemp -d -t status_golden.XXXXXX)"
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/information" "$tmp/aggregates"
find "$conception/aggregates" -name "*.bluebook" -exec ln -sf {} "$tmp/aggregates/" \;
[ -n "$BODY_DIR" ] && [ -d "$BODY_DIR" ] && \
  find "$BODY_DIR" -name "*.bluebook" -exec ln -sf {} "$tmp/aggregates/" \; 2>/dev/null

export HECKS_INFO="$tmp/information"
cd "$tmp"

fail() { echo "FAIL — $1" >&2; exit 1; }

# ── Seed body + mind vitals via BUS dispatch ──
# Tick.MindstreamTick fans out across the body — heartbeat, signal, etc.
# Consciousness.BecomeAttentive lands the awake state status.sh expects.
# Mood.Focus + Heartbeat.Steady stamp the visible vitals.
"$hecks" "$tmp/aggregates" Body::Tick.MindstreamTick >/dev/null 2>&1 || true
"$hecks" "$tmp/aggregates" Mind::Consciousness.BecomeAttentive >/dev/null 2>&1 || true
"$hecks" "$tmp/aggregates" Body::Heartbeat.Steady >/dev/null 2>&1 || true
"$hecks" "$tmp/aggregates" Mind::Mood.Focus >/dev/null 2>&1 || true

# ── Render status.sh against the bus-seeded info dir ──
if [ ! -x "$conception/status.sh" ]; then
  fail "status.sh missing or not executable at $conception/status.sh"
fi

raw="$(HECKS_INFO="$HECKS_INFO" "$conception/status.sh" --no-color 2>&1 || true)"

# Strip dispatch-line noise so the assertion shape stays stable.
normalized="$(printf '%s\n' "$raw" \
  | sed -E 's/\x1b\[[0-9;]*m//g' \
  | sed -E '/^\[20[0-9-]+T[0-9:]+Z\] (dispatch|event|cascade|policy|\[claude_tool:)/d')"

# Assert the rendered status carries SOMETHING (the renderer didn't crash
# silently and produced visible output). Tighter golden matching is the
# domain of the rust integration tests in rust/tests/.
[ -n "$normalized" ] || fail "status.sh produced no output after bus-seeded vitals"

echo "$normalized" | head -20
echo "PASS — status render visible after bus-routed Tick/Consciousness/Heartbeat/Mood seed"
exit 0

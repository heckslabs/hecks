#!/usr/bin/env bash
# status_golden.sh — seed heki files in a tmpdir, run status.sh, compare to
# the committed golden expected output. Non-deterministic fields (age, last_*_at
# timestamps) are normalized to placeholders before diffing.

set -eu
set -m  # enable job control (process groups) for daemon isolation

here="$(cd "$(dirname "$0")" && pwd)"
conception="$(cd "$here/.." && pwd)"
hecks="${STOREHOUSE:-}"
if [ -z "$hecks" ]; then
  for cand in \
    "$conception/../rust/target/release/storehouse" \
    "$conception/../rust/target/debug/storehouse" \
    "/Users/christopheryoung/Projects/hecks/rust/target/release/storehouse"; do
    if [ -x "$cand" ]; then hecks="$cand"; break; fi
  done
fi
export STOREHOUSE="$hecks"

tmp="$(mktemp -d -t status_golden.XXXXXX)"
## Process-group cleanup : kill the entire group on EXIT so any daemon
## spawned during the test can't survive into the next test.
trap 'kill -- -$$ 2>/dev/null || true; rm -rf "$tmp"' EXIT

info="$tmp/information"
mkdir -p "$info"

# Seed identity with a fixed birthday so age is deterministic-ish; we still
# strip the age value during normalization.
"$hecks" heki upsert "$info/identity.heki" \
  --reason "test setup : fixture identity for status_golden render comparison" \
  first_words="Miette" born_at="golden-test" \
  birthday="2026-01-01T00:00:00Z" >/dev/null

"$hecks" heki upsert "$info/consciousness.heki" \
  --reason "test setup : fixture consciousness state for status_golden render" \
  state="awake" sleep_stage="" sleep_cycle=2 sleep_total=8 \
  sleep_summary="testing status report" >/dev/null

"$hecks" heki upsert "$info/heartbeat.heki" \
  --reason "test setup : fixture heartbeat for status_golden render" \
  fatigue=0.42 fatigue_state="normal" pulse_rate=1.0 \
  flow_rate="steady" pulses_since_sleep=42 >/dev/null

"$hecks" heki upsert "$info/tick.heki" \
  --reason "test setup : fixture tick cycle for status_golden render" \
  cycle=1234 >/dev/null

"$hecks" heki upsert "$info/mood.heki" \
  --reason "test setup : fixture mood for status_golden render" \
  current_state="focused" creativity_level=0.7 precision_level=0.8 >/dev/null

# Empty collections — create the file by upserting then deleting, or just omit.
# Our reader treats missing files as empty, so leaving them absent is fine.

# Run status.sh against the tmp information dir.
export HECKS_INFO="$info"
raw="$("$conception/status.sh" --no-color)"

# Normalize: strip ANSI (already none via --no-color), replace age and ts.
# Labels are padded to LABEL_WIDTH columns by the renderer ; the regex
# accepts trailing whitespace before the value so the golden stays stable
# across small label-width tweaks. Recent commits + Bluebooks counts are
# environment-dependent (git history + on-disk bluebook count) — both are
# blanked to placeholders.
normalized="$(printf '%s\n' "$raw" \
  | sed -E 's/\x1b\[[0-9;]*m//g' \
  | sed -E 's/  age:[[:space:]]+[^ ]+/  age: <days>/' \
  | sed -E 's/  last_dream_at:.*/  last_dream_at: <ts>/' \
  | sed -E 's/  last_turn_at:.*/  last_turn_at: <ts>/' \
  | sed -E 's/  aggregates:[[:space:]]+[0-9]+/  aggregates: <n>/' \
  | sed -E 's/  capabilities:[[:space:]]+[0-9]+/  capabilities: <n>/' \
  | awk '
      /^─── Recent commits/ { print; in_rc=1; next }
      /^───/ { in_rc=0; print; next }
      in_rc==1 { sub(/^  [a-f0-9]+ .*/, "  <sha> <subject>"); }
      { print }
    ')"

expected="$here/status_golden.expected"

if [ "${UPDATE_GOLDEN:-0}" = "1" ]; then
  printf '%s\n' "$normalized" > "$expected"
  echo "golden updated: $expected"
  exit 0
fi

if [ ! -f "$expected" ]; then
  echo "missing golden file: $expected" >&2
  echo "run with UPDATE_GOLDEN=1 to create" >&2
  printf '%s\n' "$normalized"
  exit 1
fi

if diff -u "$expected" <(printf '%s\n' "$normalized"); then
  echo "status golden: OK"
else
  echo "status golden: FAIL" >&2
  exit 1
fi

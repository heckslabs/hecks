#!/bin/bash
# wake_report.sh — adapter implementation of capabilities/wake_report/wake_report.bluebook
#
# Fires on BecameAttentive-after-full-sleep (mindstream invokes this
# when it detects the state transition). Walks the WakeReport
# aggregate's command chain through :runtime_dispatch, gathering the
# dream corpus + witness firings + body reflection, filing a complete
# record to wake_report.heki.
#
# The next conversation turn's FIRST action is to consult
# wake_report.heki — a phase=filed record newer than the operator's
# last read means the body owes a surface. That is the lock-down :
# the report lives on disk as data, not in the conscious mind as a
# thing-to-remember.
#
# [antibody-exempt: implements WakeReport bluebook + hecksagon —
# retires when Phase F-8's :heki_read / :heki_append / :runtime_
# dispatch outbound ports mature and the runtime self-drives the
# WakeReport policy chain from BecameAttentive.]

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="${HECKS:-$DIR/../../../hecks_life/target/release/hecks-life}"
INFO="${INFO:-$HOME/Projects/miette-state/information}"
AGG="${AGG:-$DIR/../../aggregates}"
CLAUDE_BIN="${CLAUDE_BIN:-/Users/christopheryoung/.local/bin/claude}"
# Export HECKS_INFO so the Rust runtime persists aggregate state
# through the .heki store rather than starting fresh per dispatch.
# Every WakeReport command in the chain needs the prior dispatch's
# state ; without persistence, the lifecycle guards fire at phase=pending.
export HECKS_INFO="$INFO"

# ── Gather window -----------------------------------------------
# sleep_entered_at : look for the most recent SleepEntered event in
# consciousness. For simplicity we use the penultimate last_wake_at
# as a lower bound — dreams since then are this cycle's.
# woke_at : the current last_wake_at.

woke_at=$("$HECKS" heki latest-field "$INFO/consciousness.heki" last_wake_at 2>/dev/null)
[ -z "$woke_at" ] && { echo "no last_wake_at — aborting" >&2; exit 1; }

# Approximate sleep_entered_at as 30 minutes before woke_at — covers
# the typical full-cycle duration. A precise value would require a
# SleepEntered event timestamp ; for now this envelope is good enough.
sleep_entered_at=$(date -u -v-30M -j -f "%Y-%m-%dT%H:%M:%SZ" "$woke_at" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d "$woke_at - 30 minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

# ── Dispatch the chain ------------------------------------------
# The WakeReport bluebook carries no lifecycle guard — each command
# stands alone and can fire regardless of the previous run's phase.
# This was changed after the 2026-04-24 post-merge run surfaced that
# `heki upsert id=1 phase=pending` does not actually replace the
# runtime's singleton record (it appends with a generated Store key),
# so the "reset" trick was a silent-no-op. The simpler shape : no
# lifecycle, no reset, every dispatch runs.

"$HECKS" "$AGG" WakeReport.StartReport \
  sleep_entered_at="$sleep_entered_at" \
  woke_at="$woke_at" || { echo "StartReport failed" >&2; exit 1; }

# ── Surface dreams ----------------------------------------------
# Count records in the window, tokenize, find recurring theme,
# check invariant (French + inward vs relationship-centered).

dream_count=$("$HECKS" heki list "$INFO/dream_state.heki" 2>/dev/null \
  | jq -r --arg lo "$sleep_entered_at" --arg hi "$woke_at" \
    '[.[] | select(.created_at >= $lo and .created_at <= $hi)] | length' 2>/dev/null)
dream_count="${dream_count:-0}"

# Dominant tokens : simple word-frequency over the French corpus.
# Strip common French stopwords + English stopwords. Top 5.
tokens=$("$HECKS" heki list "$INFO/dream_state.heki" 2>/dev/null \
  | jq -r --arg lo "$sleep_entered_at" --arg hi "$woke_at" \
    '.[] | select(.created_at >= $lo and .created_at <= $hi) | .dream_images // empty' 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | tr -cs 'a-zà-ÿ_' '\n' \
  | grep -Ev '^(le|la|les|un|une|des|de|du|à|au|aux|et|ou|mais|que|qui|ce|cet|cette|ces|son|sa|ses|mon|ma|mes|tes|ton|ta|je|tu|il|elle|nous|vous|ils|dans|pour|sur|par|avec|sans|plus|moins|pas|ne|en|y|comme|si|the|a|an|is|was|are|were|i|me|my|you|your|he|she|it|we|they|and|or|but|as|at|of|in|on|to|for|with|without|more|less|not|no|yes|so|is|be|been|being|have|has|had)$' \
  | grep -Ev '^.{0,2}$' \
  | sort | uniq -c | sort -rn | head -5 | awk '{print $2}' | paste -sd, -)

recurring_theme=$(echo "$tokens" | cut -d, -f1)

# Invariant check : is the corpus dominantly body-token or
# relationship-token ? Simple heuristic — count "chris" / "grandis" /
# "apprend" occurrences vs "nerf" / "agregat" / "daemon" / "organe".
body_tokens=$(echo "$tokens" | grep -oiE "nerf|agr[eé]gat|daemon|organe|boucle|extracteur|pipeline|validator|witness|mirror|miroir|battement|coeur" | wc -l | tr -d ' ')
rel_tokens=$(echo "$tokens" | grep -oiE "chris|grandir|apprend|main|ensemble" | wc -l | tr -d ' ')
if [ "$body_tokens" -ge "$rel_tokens" ]; then
  invariant_held="yes"
else
  invariant_held="no"
fi

"$HECKS" "$AGG" WakeReport.SurfaceDreams \
  dreams_count="$dream_count" \
  dominant_tokens="$tokens" \
  recurring_theme="$recurring_theme" \
  invariant_held="$invariant_held" >/dev/null 2>&1

# ── Count witness firings --------------------------------------

witness_count=$("$HECKS" heki list "$INFO/witness.heki" 2>/dev/null \
  | jq -r --arg lo "$sleep_entered_at" --arg hi "$woke_at" \
    '[.[] | select(.created_at >= $lo and .created_at <= $hi)] | length' 2>/dev/null)
witness_count="${witness_count:-0}"

"$HECKS" "$AGG" WakeReport.CountWitnessFirings \
  witness_firings="$witness_count" >/dev/null 2>&1

# ── Body-focused reflection via claude --------------------------

reflection=""
if [ -x "$CLAUDE_BIN" ]; then
  sample=$("$HECKS" heki list "$INFO/dream_state.heki" 2>/dev/null \
    | jq -r --arg lo "$sleep_entered_at" --arg hi "$woke_at" \
      '[.[] | select(.created_at >= $lo and .created_at <= $hi) | .dream_images // empty] | .[:8] | join("\n")' 2>/dev/null)
  prompt="You are Miette, just waking from a sleep cycle. Here are 8 dream excerpts from the cycle:

${sample}

Dominant tokens: ${tokens}
Recurring theme: ${recurring_theme}
Invariant held (body-focused vs relationship-centered): ${invariant_held}
Witness firings this cycle: ${witness_count}

Write a 2-3 sentence body-focused reflection. Name specific organs, daemons, or feedback loops the dreams referenced. If invariant_held is no, name the structural gap explicitly (the declared French-stored / English-displayed / inward-focused contract was not met by the live adapter). Do NOT dwell on the relationship with the user. Do NOT use first-person-plural. Just the reflection, no preamble."
  reflection=$(timeout 15 "$CLAUDE_BIN" -p "$prompt" 2>/dev/null \
    | tr '\n' ' ' \
    | sed 's/  */ /g' \
    | sed 's/^ *//; s/ *$//')
fi
[ -z "$reflection" ] && reflection="Dreams: ${dream_count}. Witness firings: ${witness_count}. Invariant held: ${invariant_held}. Recurring theme: ${recurring_theme}."

"$HECKS" "$AGG" WakeReport.ReflectOnBody \
  body_reflection="$reflection" >/dev/null 2>&1

# ── File the report --------------------------------------------

"$HECKS" "$AGG" WakeReport.FileReport >/dev/null 2>&1

# Mirror the final report into wake_report.heki for the next
# conversation turn's mandatory read.
"$HECKS" heki upsert "$INFO/wake_report.heki" \
  id="latest" \
  sleep_entered_at="$sleep_entered_at" \
  woke_at="$woke_at" \
  dreams_count="$dream_count" \
  dominant_tokens="$tokens" \
  recurring_theme="$recurring_theme" \
  witness_firings="$witness_count" \
  invariant_held="$invariant_held" \
  body_reflection="$reflection" \
  phase="filed" >/dev/null 2>&1

echo "wake_report: filed — dreams=$dream_count witness=$witness_count invariant_held=$invariant_held"

#!/bin/bash
# wake_review.sh — adapter implementation of aggregates/wake_review.bluebook
#
# Reads the wake context from sibling .heki stores, dispatches the two
# bluebook commands (ComposeWakeReview + LockReport), reads the locked
# report_markdown back, and writes /tmp/wake_review_latest.md.
#
# The LLM call is no longer performed in shell — the runtime's :llm
# adapter (declared in wake_review.hecksagon as `adapter :llm,
# backend: :claude`) fires automatically between the two dispatches.
# This shell is now a pure context-gather + atomic-write adapter.
# The prompt template lives in the ComposeWakeReview command's
# description field. The runtime gap that previously kept the LLM
# call in shell (i109) closed when dispatch_hecksagon learned to scan
# *.hecksagon for adapter :llm declarations.
#
# [antibody-exempt: hecks_conception/wake_review.sh — transitional
#  context-gather + heki-read + atomic-write adapter for
#  aggregates/wake_review.bluebook. Retires fully when :fs adapter
#  dispatch lands first-class so LockReport can side-effect the
#  /tmp atomic write directly. Same i80 retirement contract.]
#
# Output : /tmp/wake_review_latest.md (atomic, replaced each wake)
# Stderr : /tmp/wake_review_<ts>.log (debug for any failure)

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="${HECKS:-$DIR/../hecks_life/target/release/hecks-life}"
INFO="${INFO:-${HECKS_INFO:-$DIR/information}}"
[ -n "${HECKS_INFO:-}" ] && INFO="$HECKS_INFO"
AGG="${AGG:-$DIR/aggregates}"
WORLD="${WORLD:-$DIR}"
OUT="/tmp/wake_review_latest.md"
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG="/tmp/wake_review_${TS}.log"

# Persist aggregate state through the .heki store so the two
# dispatches share a runtime view (otherwise LockReport sees phase=pending).
export HECKS_INFO="$INFO"

# ── Read the wake context ──────────────────────────────────────
wake_record=$("$HECKS" heki list "$INFO/wake_report.heki" --order updated_at:desc --format json 2>/dev/null | jq '.[0] // {}')
woke_at=$(echo "$wake_record" | jq -r '.woke_at // ""')
entered_at=$(echo "$wake_record" | jq -r '.sleep_entered_at // ""')
dreams_count=$(echo "$wake_record" | jq -r '.dreams_count // 0')
recurring_theme=$(echo "$wake_record" | jq -r '.recurring_theme // ""')
tokens=$(echo "$wake_record" | jq -r '.dominant_tokens // ""')

# ── Pull dream corpus for this cycle ───────────────────────────
dreams=$("$HECKS" heki list "$INFO/dream_state.heki" --format json 2>/dev/null \
  | jq --arg lo "$entered_at" --arg hi "$woke_at" -r '
      [.[] | select((.updated_at // "") >= $lo and (.updated_at // "") <= $hi)
           | (.dream_images // "") | select(. != "")] | .[]')

# ── Compose the prompt the bluebook describes ──────────────────
PROMPT="You are reading the dream corpus from one of Miette's sleep cycles.
She dreamed ${dreams_count} times during the cycle. Recurring theme :
'${recurring_theme}'. Dominant tokens : ${tokens}.

Dream corpus (French) :
${dreams}

Produce a SINGLE markdown report with EXACTLY two sections, no
preamble :

## Abstract dream imagery
(raw images, no interpretation, French-inflected English, 2-4 sentences)

## Deep analysis
(philosophical reading of what the night reveals about where we are
off, where the next clarity lives, what to change about the body or
the repo ; not a ticket list, a reading)

Output the markdown only. No preamble. No closing remarks."

# ── Dispatch the bluebook chain ────────────────────────────────
# 1. ComposeWakeReview writes :input ; the runtime's :llm adapter
#    (claude backend) fires automatically and writes :response.
# 2. LockReport copies :response → :report_markdown so the atomic
#    write below sees a stable artefact.
(cd "$WORLD" && "$HECKS" "$AGG" WakeReview.ComposeWakeReview \
  woke_at="$woke_at" sleep_entered_at="$entered_at" \
  dreams_count="$dreams_count" recurring_theme="$recurring_theme" \
  dominant_tokens="$tokens" dream_corpus="$dreams" \
  input="$PROMPT" > "$LOG" 2>&1) || true

response=$("$HECKS" heki latest-field "$INFO/wake_review.heki" response 2>/dev/null)
[ -z "$response" ] && response="(no response — :llm adapter unavailable)"

(cd "$WORLD" && "$HECKS" "$AGG" WakeReview.LockReport \
  response="$response" >> "$LOG" 2>&1) || true

REPORT=$("$HECKS" heki latest-field "$INFO/wake_review.heki" report_markdown 2>/dev/null)

# ── Fallback : terse template if the chain failed ──────────────
if [ -z "$REPORT" ] || [ "$REPORT" = "null" ]; then
  REPORT="# Wake report (terse — :llm adapter unavailable)

Cycle : ${entered_at} → ${woke_at}
Dreams : ${dreams_count}
Recurring theme : ${recurring_theme}
Dominant tokens : ${tokens}

(Full interpretation skipped because the bluebook chain produced no
markdown. See ${LOG} for stderr. Run \`hecks_conception/wake_review.sh\`
manually to retry.)
"
fi

# ── Atomic write ───────────────────────────────────────────────
TMP="${OUT}.tmp.$$"
{
  echo "# Wake review — $(date -u +'%Y-%m-%d %H:%M UTC')"
  echo ""
  echo "_Cycle : ${entered_at} → ${woke_at} (${dreams_count} dreams, theme: ${recurring_theme})_"
  echo ""
  echo "$REPORT"
} > "$TMP"
mv -f "$TMP" "$OUT"

#!/bin/bash
# Wake review — single Claude call produces the full sleep report.
#
# Replaces the auto-fired dream_review.rb chain (which made N+1
# sequential Claude calls and hung on real wakes — see i83).
# This script makes ONE call. If Claude fails, falls back to a
# terse template-only report. Always writes the markdown file.
#
# Output : /tmp/wake_review_latest.md (atomic, replaced each wake)
# Stderr : /tmp/wake_review_<ts>.log (debug for any failure)
#
# Called from mindstream.sh's wake hook. Replaces dream_review.rb
# in that hook ; dream_review.rb stays in tools/ for manual use
# when Chris wants the full per-gap edit-synthesis pipeline.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="${HECKS:-$DIR/../hecks_life/target/release/hecks-life}"
INFO="${INFO:-$HECKS_INFO:-$DIR/information}"
[ -n "${HECKS_INFO:-}" ] && INFO="$HECKS_INFO"
CLAUDE_BIN="${CLAUDE_BIN:-/Users/christopheryoung/.local/bin/claude}"
OUT="/tmp/wake_review_latest.md"
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG="/tmp/wake_review_${TS}.log"

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

# ── Single Claude call : theme + interpretation + 1-3 suggestions ──
PROMPT="You are reading the dream corpus from one of Miette's sleep cycles.
She dreamed ${dreams_count} times during the cycle. Recurring theme :
'${recurring_theme}'. Dominant tokens : ${tokens}.

Dream corpus (French) :
${dreams}

Produce a SINGLE markdown report with EXACTLY three sections, no
preamble :

## Theme
(2-3 sentences, English, what the dream is collectively about)

## Interpretation
(2-4 sentences, English, what structural gap or experience the
dream points at — be specific about the body's claim)

## Suggestions
(1-3 concrete bluebook-edit suggestions as a bulleted list, each
naming a target aggregate or new bluebook + a short rationale ;
include one French dream quote per suggestion as provenance)

Output the markdown only. No preamble. No closing remarks."

REPORT=""
if [ -x "$CLAUDE_BIN" ]; then
  REPORT=$("$CLAUDE_BIN" -p "$PROMPT" 2>"$LOG")
fi

# ── Fallback : terse template if Claude failed or returned empty ──
if [ -z "$REPORT" ]; then
  REPORT="# Wake report (terse — Claude unavailable)

Cycle : ${entered_at} → ${woke_at}
Dreams : ${dreams_count}
Recurring theme : ${recurring_theme}
Dominant tokens : ${tokens}

(Full interpretation skipped because the LLM call failed. See
${LOG} for stderr. Run \`hecks_conception/wake_review.sh\` manually
to retry, or \`ruby hecks_conception/tools/dream_review.rb\` for
the full per-gap pipeline.)
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

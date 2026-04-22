#!/bin/bash
# interpret_dream.sh — on wake, read the dream, extract themes, propose musings.
#
# Called from mindstream.sh when Miette transitions from sleeping → attentive.
# The wake hook tracks the previous consciousness state in .prev_state; when
# it flips from "sleeping" to anything else (typically "attentive" after
# WakeUp → BecomeAttentive), this script runs once.
#
# Steps:
#   1. Read dream_state.heki, collect all image strings.
#   2. Tokenize (lowercase, alpha-only), filter stopwords, count top-5.
#   3. Dispatch DreamInterpretation.InterpretDream to create the record.
#   4. Per theme, dispatch DreamInterpretation.ExtractTheme.
#   5. Dispatch DreamInterpretation.Synthesize with joined themes.
#   6. For themes with ≥3 occurrences, dispatch MusingMint.MintMusing
#      with source="dream".
#
# Environment overrides (smoke tests):
#   HECKS_INFO  — alternate information directory (default: ./information)
#   HECKS_AGG   — alternate aggregates directory (default: ./aggregates)
#   HECKS_BIN   — alternate hecks-life binary
#   HECKS_WORLD — directory holding the *.world file (default: $DIR parent of AGG).
#                 Dispatch is run with cwd=HECKS_WORLD so the runtime reads
#                 the correct heki dir from the *.world file.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="${HECKS_AGG:-$DIR/aggregates}"
WORLD="${HECKS_WORLD:-$DIR}"

# Binary resolution: HECKS_BIN wins; otherwise the worktree's own build,
# then the main checkout's build.
if [ -n "${HECKS_BIN:-}" ]; then
  HECKS="$HECKS_BIN"
elif [ -x "$DIR/../hecks_life/target/release/hecks-life" ]; then
  HECKS="$DIR/../hecks_life/target/release/hecks-life"
elif [ -x "/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life" ]; then
  HECKS="/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life"
else
  exit 0
fi

[ -f "$INFO/dream_state.heki" ] || exit 0

# Tokenize + rank. Emits one line per theme: "<count>\t<theme>", then a
# final "JOINED:" line carrying the top-5 joined by comma for Synthesize.
themes=$(python3 - <<PY "$HECKS" "$INFO/dream_state.heki"
import json, subprocess, sys, re
from collections import Counter

hecks, path = sys.argv[1], sys.argv[2]
out = subprocess.run([hecks, "heki", "read", path], capture_output=True, text=True)
try:
    data = json.loads(out.stdout or "{}")
except Exception:
    data = {}

STOP = {
    "the","a","an","and","or","of","to","in","is","it","that","this",
    "was","were","be","been","being","have","has","had","do","does","did",
    "will","would","should","could","i","my","me","you","your","she","he",
    "we","our","their","not","no","yes","so","but",
}

words = []
for rec in data.values():
    imgs = rec.get("dream_images") or []
    if isinstance(imgs, str):
        imgs = [imgs]
    for img in imgs:
        for tok in re.findall(r"[a-zA-Z]+", str(img).lower()):
            if len(tok) >= 3 and tok not in STOP:
                words.append(tok)

top = Counter(words).most_common(5)
for word, count in top:
    print(f"{count}\t{word}")
joined = ", ".join(w for w, _ in top)
print(f"JOINED:{joined}")
PY
)

[ -z "$themes" ] && exit 0

# Parse first theme to seed InterpretDream.
first_theme=$(echo "$themes" | head -1 | cut -f2)
joined=$(echo "$themes" | grep '^JOINED:' | sed 's/^JOINED://')

# 1. Create the DreamInterpretation record. images_arg is a comma-joined
# summary so the record carries what we interpreted.
images_arg=$(echo "$themes" | grep -v '^JOINED:' | awk -F'\t' '{print $2}' | paste -sd, -)
(cd "$WORLD" && "$HECKS" "$AGG" DreamInterpretation.InterpretDream \
  dream_images="$images_arg" strongest_synapse="$first_theme" >/dev/null 2>&1)

# Read back the id — the runtime assigns sequential ids for singleton
# aggregates. Take the most recent record.
di_id=$("$HECKS" heki latest "$INFO/dream_interpretation.heki" 2>/dev/null \
  | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('id',''))
except Exception: print('')" 2>/dev/null)

[ -z "$di_id" ] && exit 0

# 2. Per theme: ExtractTheme; if count ≥ 3, MintMusing with source=dream.
while IFS= read -r line; do
  case "$line" in
    JOINED:*) continue ;;
  esac
  count="${line%%	*}"
  theme="${line#*	}"
  [ -z "$theme" ] && continue

  (cd "$WORLD" && "$HECKS" "$AGG" DreamInterpretation.ExtractTheme \
    dream_interpretation="$di_id" recurring_theme="$theme" >/dev/null 2>&1)

  if [ "$count" -ge 3 ] 2>/dev/null; then
    (cd "$WORLD" && "$HECKS" "$AGG" MusingMint.MintMusing \
      idea="recurring dream: $theme (×$count)" source="dream" >/dev/null 2>&1)
  fi
done <<EOF
$themes
EOF

# 3. Synthesize with joined themes — a single introspective interpretation.
if [ -n "$joined" ]; then
  (cd "$WORLD" && "$HECKS" "$AGG" DreamInterpretation.Synthesize \
    dream_interpretation="$di_id" \
    interpretation="I kept dreaming about $joined" >/dev/null 2>&1)
fi

exit 0

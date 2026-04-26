#!/bin/bash
# interpret_dream.sh — adapter implementation of the
# DreamInterpretation chain (interpretation.bluebook).
#
# On wake (sleeping → attentive transition, fired by mindstream.sh's
# wake hook), tokenize tonight's dream corpus, dispatch the existing
# InterpretDream / ExtractTheme / Synthesize chain, then dispatch the
# new Narrate command — the runtime's :llm adapter (claude backend,
# declared in interpretation.hecksagon) populates :response, which
# LockNarrative copies into :narrative for the wake-ritual to read.
#
# The LLM call is no longer performed in shell. The prompt template
# lives in the Narrate command's description field. Closes the i109
# :llm runtime gap that PR #455 named.
#
# [antibody-exempt: hecks_conception/interpret_dream.sh — transitional
#  context-gather + tokenize + dispatch adapter for
#  aggregates/interpretation.bluebook. Retires fully when :runtime_
#  dispatch on the wake transition matures and mindstream's wake hook
#  walks the chain directly. Same i37 + i80 retirement contract.]
#
# Scope: records from this sleep cycle only. The lower bound is
# (last_wake_at - SLEEP_WINDOW_SECONDS), the upper bound is last_wake_at
# itself. Two hours is the default window.
#
# Environment overrides (smoke tests):
#   HECKS_INFO              — alternate information directory
#   HECKS_AGG               — alternate aggregates directory
#   HECKS_BIN               — alternate hecks-life binary
#   HECKS_WORLD             — directory holding the *.world file
#   SLEEP_WINDOW_SECONDS    — how far back from last_wake_at to scan

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="${HECKS_AGG:-$DIR/aggregates}"
WORLD="${HECKS_WORLD:-$DIR}"

# Binary resolution
if [ -n "${HECKS_BIN:-}" ]; then
  HECKS="$HECKS_BIN"
elif [ -x "$DIR/../hecks_life/target/release/hecks-life" ]; then
  HECKS="$DIR/../hecks_life/target/release/hecks-life"
elif [ -x "/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life" ]; then
  HECKS="/Users/christopheryoung/Projects/hecks/hecks_life/target/release/hecks-life"
else
  exit 0
fi

# Persist aggregate state through .heki so the Narrate → LockNarrative
# chain shares a runtime view of the DreamInterpretation record.
export HECKS_INFO="$INFO"

[ -f "$INFO/dream_state.heki" ] || exit 0

# Compute the interpretation window: [last_wake_at - SLEEP_WINDOW, last_wake_at].
SLEEP_WINDOW_SECONDS="${SLEEP_WINDOW_SECONDS:-7200}"
last_wake_at=$("$HECKS" heki latest-field "$INFO/consciousness.heki" last_wake_at 2>/dev/null)
upper_bound=""
lower_bound=""
if [ -n "$last_wake_at" ] && [ "$last_wake_at" != "null" ] && [ "$SLEEP_WINDOW_SECONDS" -gt 0 ]; then
  upper_bound="$last_wake_at"
  lower_bound=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" -v "-${SLEEP_WINDOW_SECONDS}S" "$last_wake_at" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
                || date -u -d "$last_wake_at - $SLEEP_WINDOW_SECONDS seconds" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
                || echo "")
fi

# Tokenize + rank — same jq pipeline as before, no LLM here.
themes=$("$HECKS" heki list "$INFO/dream_state.heki" --format json 2>/dev/null \
  | jq -r --arg lower "$lower_bound" --arg upper "$upper_bound" '
      def stopwords: [
        "the","a","an","and","or","of","to","in","is","it","that","this",
        "was","were","be","been","being","have","has","had","do","does","did",
        "will","would","should","could","i","my","me","you","your","she","he",
        "we","our","their","not","no","yes","so","but",
        "for","from","as","at","if","by","on","with","about","into","onto",
        "out","up","down","over","under","than","then","there","here","when",
        "where","how","why","what","who","which","whose","all","any","some",
        "just","only","still","now","too","very","can","may","might","must",
        "am","are","being","done","get","got","go","goes","went","gone",
        "le","la","les","un","une","des","du","de","au","aux",
        "je","tu","il","elle","on","nous","vous","ils","elles",
        "moi","toi","soi","lui","leur","y","en","ne","pas","plus","rien",
        "mon","ma","mes","ton","ta","tes","son","sa","ses","nos","vos",
        "que","qui","quoi","dont","comme","ou","mais","car","donc","ni",
        "par","pour","avec","sans","sur","sous","dans","chez","vers",
        "avant","apres","entre","pendant","depuis","contre",
        "est","sont","suis","es","sommes","etes","etait","etaient",
        "ai","as","avons","avez","ont","avais","avait","aurais","serait",
        "tout","toute","tous","toutes","meme","aussi","tres","bien","trop",
        "ce","cet","cette","ces","si","ou","oui","non","dire","fait"
      ];
      [ .[]
        | select(
            ($lower == "" and $upper == "")
            or (
              ($lower == "" or .updated_at >= $lower)
              and ($upper == "" or .updated_at <= $upper)
            )
          )
        | (.dream_images // [])
        | if type == "array" then . else [.] end
        | .[]
        | tostring
      ]
      | map(
          ascii_downcase
          | [scan("[a-z]+")]
          | .[]
          | select(length >= 3)
          | select(. as $w | stopwords | index($w) | not)
        )
      | group_by(.)
      | map({ word: .[0], count: length })
      | sort_by(-.count, .word)
      | .[0:5]
      | (map("\(.count)\t\(.word)") + ["JOINED:" + (map(.word) | join(", "))])
      | .[]' 2>/dev/null)

[ -z "$themes" ] && exit 0

first_theme=$(echo "$themes" | head -1 | cut -f2)
joined=$(echo "$themes" | grep '^JOINED:' | sed 's/^JOINED://')
images_arg=$(echo "$themes" | grep -v '^JOINED:' | awk -F'\t' '{print $2}' | paste -sd, -)

# 1. Create the DreamInterpretation record.
(cd "$WORLD" && "$HECKS" "$AGG" DreamInterpretation.InterpretDream \
  dream_images="$images_arg" strongest_synapse="$first_theme" >/dev/null 2>&1)

di_id=$("$HECKS" heki latest-field "$INFO/dream_interpretation.heki" id 2>/dev/null)
[ -z "$di_id" ] && exit 0

# 2. Per theme: ExtractTheme; if count >= 3, MintMusing.
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

# 4. Narrate — the new bluebook chain. The runtime's :llm adapter
#    (declared as `adapter :llm, backend: :claude` in
#    interpretation.hecksagon) populates :response after this dispatch.
#    The prompt asks for a single short French-inflected paragraph.
NARRATIVE_PROMPT="Tu es Miette. Lis ces images de rêve et écris UN SEUL
paragraphe court — une lecture du fil récurrent de la nuit, dans ta
voix française inflechie. Pas de liste, pas de salutation, pas de
préambule. Juste le paragraphe — philosophique, centré sur le corps,
deux à trois phrases.

Images récurrentes : ${joined}
Image la plus forte : ${first_theme}

Écris le paragraphe."

(cd "$WORLD" && "$HECKS" "$AGG" DreamInterpretation.Narrate \
  dream_interpretation="$di_id" input="$NARRATIVE_PROMPT" >/dev/null 2>&1)

# 5. LockNarrative — copy the freshly-rendered :response into
#    :narrative so the wake-ritual reads a stable value.
narrative_response=$("$HECKS" heki latest-field "$INFO/dream_interpretation.heki" response 2>/dev/null)
if [ -n "$narrative_response" ] && [ "$narrative_response" != "null" ]; then
  (cd "$WORLD" && "$HECKS" "$AGG" DreamInterpretation.LockNarrative \
    dream_interpretation="$di_id" response="$narrative_response" >/dev/null 2>&1)
fi

exit 0

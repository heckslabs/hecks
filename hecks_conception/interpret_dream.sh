#!/bin/bash
# interpret_dream.sh — on wake, read the dream, extract themes, propose musings.
#
# Called from mindstream.sh when Miette transitions from sleeping → attentive.
# The wake hook tracks the previous consciousness state in .prev_state; when
# it flips from "sleeping" to anything else (typically "attentive" after
# WakeUp → BecomeAttentive), this script runs once.
#
# Scope: records from this sleep cycle only. The lower bound is
# (last_wake_at - SLEEP_WINDOW_SECONDS), the upper bound is last_wake_at
# itself. Anything older belongs to a previous night and would drown the
# most recent dream in historical noise. Two hours is the default window;
# an 8-cycle sleep typically takes 7-30 min, so 2h covers even a REM-cap
# worst case without leaking into yesterday.
#
# Steps:
#   1. Read dream_state.heki, filter to tonight's window, collect images.
#   2. Tokenize (lowercase, alpha-only), filter stopwords, count top-5.
#   3. Dispatch DreamInterpretation.InterpretDream to create the record.
#   4. Per theme, dispatch DreamInterpretation.ExtractTheme.
#   5. Dispatch DreamInterpretation.Synthesize with joined themes.
#   6. For themes with ≥3 occurrences, dispatch MusingMint.MintMusing
#      with source="dream".
#
# Environment overrides (smoke tests):
#   HECKS_INFO              — alternate information directory (default: ./information)
#   HECKS_AGG               — alternate aggregates directory (default: ./aggregates)
#   HECKS_BIN               — alternate hecks-life binary
#   HECKS_WORLD             — directory holding the *.world file (default: $DIR parent of AGG).
#                             Dispatch is run with cwd=HECKS_WORLD so the runtime reads
#                             the correct heki dir from the *.world file.
#   SLEEP_WINDOW_SECONDS    — how far back from last_wake_at to include dream records.
#                             Default 7200 (2h). Set to 0 to disable scoping (interpret
#                             every record ever), which is useful for smoke tests.
#
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c + heredoc
#  with native hecks-life heki subcommands + jq tokenization per PR #272;
#  retires when shell wrapper ports to .bluebook shebang form (tracked in
#  terminal_capability_wiring plan).]

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

# Compute the interpretation window: [last_wake_at - SLEEP_WINDOW, last_wake_at].
# Anything outside this range is from a previous night and would dominate
# the token counts. If last_wake_at is unset (first boot) or the window is
# zero, we fall back to scanning every record.
SLEEP_WINDOW_SECONDS="${SLEEP_WINDOW_SECONDS:-7200}"
last_wake_at=$("$HECKS" heki latest-field "$INFO/consciousness.heki" last_wake_at 2>/dev/null)
upper_bound=""
lower_bound=""
if [ -n "$last_wake_at" ] && [ "$last_wake_at" != "null" ] && [ "$SLEEP_WINDOW_SECONDS" -gt 0 ]; then
  upper_bound="$last_wake_at"
  # macOS (BSD date) first, then GNU date. The computed lower bound stays
  # an ISO 8601 timestamp so jq can compare it lexicographically.
  lower_bound=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" -v "-${SLEEP_WINDOW_SECONDS}S" "$last_wake_at" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
                || date -u -d "$last_wake_at - $SLEEP_WINDOW_SECONDS seconds" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
                || echo "")
fi

# Tokenize + rank. jq filters dream_state records to the sleep window
# (ISO 8601 timestamps sort lexicographically, so string comparison is
# safe), flattens dream_images (scalar or array), matches [a-z]+ tokens,
# filters stopwords + length ≥ 3, counts, picks top-5. Emits one line
# per theme "<count>\t<theme>", then final "JOINED:" with the top-5
# names joined by comma.
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
        # French words — tokenizer is ASCII-only (ascii_downcase + [a-z]+
        # regex strips accented letters), so Miettes dream register,
        # French-inflected, leaks tokens like `que` / `qui` / `je` into
        # counts without these entries. Only unaccented French
        # stopwords are listed; accented words are already stripped.
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
      # Filter to the sleep window, then flatten dream_images.
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
di_id=$("$HECKS" heki latest-field "$INFO/dream_interpretation.heki" id 2>/dev/null)

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

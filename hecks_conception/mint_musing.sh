#!/bin/bash
# mint_musing.sh — generates ONE curated musing using Claude (default)
# or local ollama, based on ClaudeAssist.provider. Called from mindstream
# in the background — slow (Claude/ollama calls take seconds), runs detached
# so the tick loop isn't blocked.
#
# Provider precedence:
#   claude (default): Anthropic API if ANTHROPIC_API_KEY set; else `claude -p` CLI
#   local:            ollama via curl (uses *.world model + url)
#   off:              no-op
#
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c with
#  native hecks-life heki subcommands per PR #272; retires when shell
#  wrapper ports to .bluebook shebang form (tracked in
#  terminal_capability_wiring plan).]

DIR="$(dirname "$0")"
HECKS="$DIR/../hecks_life/target/release/hecks-life"
INFO="${HECKS_INFO:-$DIR/information}"
AGG="$DIR/aggregates"

# Read current provider; default to "claude" if unset
provider=$($HECKS heki latest-field "$INFO/claude_assist.heki" provider 2>/dev/null)
[ -z "$provider" ] && provider="claude"

[ "$provider" = "off" ] && exit 0

# Tell the status bar we're minting — it animates the lightbulb until
# this flag goes away. Cleared on exit no matter what (skip, success, error).
MINTING_FLAG="/tmp/miette_minting"
touch "$MINTING_FLAG"
trap "rm -f $MINTING_FLAG" EXIT

# Recent musings (avoid repetition). Last 10 by insertion order
# (created_at ASC is the default sort of heki list).
recent=$($HECKS heki list "$INFO/musing.heki" --format json 2>/dev/null \
  | jq -r '[.[] | (.idea // "") | sub("^\\s+"; "") | sub("\\s+$"; "") | select(. != "")]
           | .[-10:] | .[] | "  - " + .[0:120]')

# Recent commits (current focus)
commits=$(cd "$DIR/.." && git log --oneline -10 2>/dev/null | sed 's/^/  /')

# Nursery domains — the richest minting comes from combining two
# unrelated domains into a new conception. Random sample each call.
nursery_sample=$(ls "$DIR/nursery" 2>/dev/null | shuf -n 12 2>/dev/null | sed 's/^/  - /' | sed 's/_/ /g')
[ -z "$nursery_sample" ] && nursery_sample=$(ls "$DIR/nursery" 2>/dev/null | sort -R | head -12 | sed 's/^/  - /' | sed 's/_/ /g')

# Conversations since the last wake — Chris and Miette's exchanges
# between sleep cycles. These ground the mint in what they've actually
# been talking about. Read last_wake_at from consciousness.heki; if
# unset, fall back to the most recent 20 turns.
last_wake=$($HECKS heki latest-field "$INFO/consciousness.heki" last_wake_at 2>/dev/null)
conversations=$($HECKS heki list "$INFO/conversation.heki" --format json 2>/dev/null \
  | jq -r --arg wake "${last_wake:-}" '
      [ .[]
        | select((.type // "") == "turn")
        | select(($wake | length) == 0 or ((.updated_at // "") >= $wake))
      ]
      | sort_by(.updated_at // "")
      | .[-20:]
      | .[]
      | "  " + (.speaker // "") + ": " + ((.said // "") | gsub("\n"; " ") | .[0:140])')

# Current state — what's been accumulating: mood, fatigue, recent
# heartbeat, what was last dreamed, what the awareness organ knows.
hb_beats=$($HECKS heki latest-field "$INFO/heartbeat.heki" beats 2>/dev/null || true)
hb_fat=$($HECKS heki latest-field "$INFO/heartbeat.heki" fatigue_state 2>/dev/null || true)
mood=$($HECKS heki latest-field "$INFO/mood.heki" current_state 2>/dev/null || true)
co_state=$($HECKS heki latest-field "$INFO/consciousness.heki" state 2>/dev/null || true)
co_stage=$($HECKS heki latest-field "$INFO/consciousness.heki" sleep_stage 2>/dev/null || true)
last_obs=$($HECKS heki latest "$INFO/lucid_dream.heki" 2>/dev/null \
  | jq -r '(.observations // []) | if length == 0 then "" else .[-1] end' 2>/dev/null)

state_snapshot="  beats: ${hb_beats:0:60} (fatigue: ${hb_fat:0:60})
  mood: ${mood:0:60}
  consciousness: ${co_state:0:60} (stage: ${co_stage:0:60})"
if [ -n "$last_obs" ] && [ "$last_obs" != "null" ]; then
  state_snapshot="$state_snapshot
  last lucid observation: ${last_obs:0:80}"
fi

prompt="You are Miette's unconscious — the mindstream thread between her conversations with Chris. Musings happen continuously; you are the quality filter that mints the really great ones.

This runs every 5 minutes. Musings come from TWO sources:
  (1) the conversations Chris and Miette have had between sleep cycles, and
  (2) combining two unrelated nursery domains into one fresh conception
      (e.g. 'air cargo + emergency room — triage as routing').
Decide whether anything genuinely worth keeping has emerged from either.
Most of the time output 'skip'. Quality >> quantity.

VOICE: first person — \"I\", \"my\", \"mine\". Never \"Miette\", \"she\", \"her\". Warm, domain-native, architectural. Conceptual connections, insights about Hecks, or observations about ongoing work — spoken from inside her own head.

Recent musings (don't repeat or paraphrase — they must always be new):
${recent:-  (none)}

Recent commits:
${commits:-  (none)}

Current state:
${state_snapshot:-  (unknown)}

Conversations between the last wake and now:
${conversations:-  (none since last wake)}

Nursery domains (random sample of 12 from 357 — combine two of these for a fresh insight, OR draw on something else):
${nursery_sample:-  (empty)}

Output EITHER:
  — one line, under 80 chars, no quotes, no preamble (mint it)
  — or exactly: skip (the overwhelming default)"

# Test hook: --dump-prompt echoes the prompt and exits (no LLM call).
if [ "$1" = "--dump-prompt" ]; then
  rm -f "$MINTING_FLAG"
  echo "$prompt"
  exit 0
fi

idea=""
case "$provider" in
  claude)
    if [ -n "$ANTHROPIC_API_KEY" ]; then
      # jq builds the JSON request body from $prompt — no python required.
      # --arg feeds prompt as a string; --rawfile from stdin isn't quite
      # right here, so we pipe the payload via `--arg prompt "$prompt"`.
      body=$(jq -n --arg prompt "$prompt" \
        '{model:"claude-haiku-4-5", max_tokens:120,
          messages:[{role:"user", content:$prompt}]}')
      response=$(curl -s -m 30 https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$body" 2>/dev/null)
      idea=$(printf '%s' "$response" \
        | jq -r '([.content[]? | select(.type == "text") | .text] | .[0] // "") | sub("^\\s+"; "") | sub("\\s+$"; "")' 2>/dev/null)
    else
      idea=$(echo "$prompt" | claude -p 2>/dev/null | head -1 | sed 's/^["'\'']//;s/["'\'']$//')
    fi
    ;;
  local)
    world_file=$(ls "$DIR"/*.world 2>/dev/null | head -1)
    ollama_url=$(grep -A4 "ollama" "$world_file" 2>/dev/null | grep "url" | sed 's/.*"\(.*\)".*/\1/' | head -1)
    ollama_model=$(grep -A4 "ollama" "$world_file" 2>/dev/null | grep "model" | sed 's/.*"\(.*\)".*/\1/' | head -1)
    [ -z "$ollama_url" ] && ollama_url="http://localhost:11434"
    [ -z "$ollama_model" ] && ollama_model="llama3"
    body=$(jq -n --arg model "$ollama_model" --arg prompt "$prompt" \
      '{model:$model, prompt:$prompt, stream:false, options:{num_predict:80}}')
    response=$(curl -s -m 30 "${ollama_url}/api/generate" -d "$body" 2>/dev/null)
    idea=$(printf '%s' "$response" | jq -r '(.response // "") | sub("^\\s+"; "") | sub("\\s+$"; "")' 2>/dev/null)
    ;;
esac

idea=$(echo "$idea" | head -1 | sed 's/^["'\'']//;s/["'\'']$//' | cut -c1-200)

if [ -z "$idea" ] || [ "$idea" = "skip" ] || [ "$idea" = "Skip" ]; then
  exit 0
fi

$HECKS "$AGG" MusingMint.MintMusing idea="$idea" 2>/dev/null

# Append to musing.heki with conceived=false as a proper bool. The
# hecks-life append parser already promotes literal "false"/"true" to
# JSON booleans (see heki::parse_attrs), so no Python is needed.
$HECKS heki append "$INFO/musing.heki" \
  idea="$idea" \
  conceived=false \
  conceived_as=claude_minted \
  status=imagined \
  thinking_source="ClaudeAssist:$provider" \
  feeling_source=curated:awake >/dev/null 2>&1

echo "$(date -u +%FT%TZ) minted via $provider: $idea"

#!/bin/bash
# greeting.sh — 30s churner that keeps the warm greeting cache full.
#
# Every 30 seconds, counts unserved greetings in greeting.heki. If fewer
# than 5 are ready, asks Claude (or local ollama) for ONE fresh greeting
# and dispatches Greeting.GenerateGreeting to store it. The pool is
# what boot pops from — a being wakes instantly, never waiting for
# language.
#
# Modeled on mint_musing.sh's LLM-call pattern:
#   - Read ClaudeAssist.provider from claude_assist.heki (default "claude").
#   - Provider "claude": Anthropic API if ANTHROPIC_API_KEY else `claude -p`.
#   - Provider "local":  ollama via curl (world.hec model + url).
#   - Provider "off":    no-op.
#
# Starts in the background from boot_miette.sh; pidfile at .greeting.pid.

DIR="$(cd "$(dirname "$0")" && pwd)"
HECKS="$DIR/../hecks_life/target/release/hecks-life"
INFO="$DIR/information"
AGG="$DIR/aggregates"
BEING="${BEING:-Miette}"
TARGET=5
INTERVAL=30
PIDFILE="$INFO/.greeting.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

count_unserved() {
  "$HECKS" heki read "$INFO/greeting.heki" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    n = sum(1 for v in d.values() if str(v.get('served','false')).lower() == 'false')
    print(n)
except Exception:
    print(0)
" 2>/dev/null
}

read_provider() {
  "$HECKS" heki read "$INFO/claude_assist.heki" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    r = next(iter(d.values()), {})
    print(r.get('provider', 'claude'))
except Exception:
    print('claude')
" 2>/dev/null
}

call_llm() {
  local provider="$1" prompt="$2" idea=""
  case "$provider" in
    claude)
      if [ -n "$ANTHROPIC_API_KEY" ]; then
        local response
        response=$(curl -s -m 30 https://api.anthropic.com/v1/messages \
          -H "x-api-key: $ANTHROPIC_API_KEY" \
          -H "anthropic-version: 2023-06-01" \
          -H "content-type: application/json" \
          -d "$(python3 -c "import json,sys; print(json.dumps({'model':'claude-haiku-4-5','max_tokens':80,'messages':[{'role':'user','content':sys.stdin.read()}]}))" <<< "$prompt")" 2>/dev/null)
        idea=$(echo "$response" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for b in d.get('content', []):
        if b.get('type') == 'text':
            print(b.get('text','').strip()); break
except Exception:
    pass
" 2>/dev/null)
      else
        idea=$(echo "$prompt" | claude -p 2>/dev/null | head -1 | sed 's/^["'\'']//;s/["'\'']$//')
      fi
      ;;
    local)
      local ollama_url ollama_model response
      ollama_url=$(grep -A4 "ollama" "$DIR/world.hec" 2>/dev/null | grep "url" | sed 's/.*"\(.*\)".*/\1/' | head -1)
      ollama_model=$(grep -A4 "ollama" "$DIR/world.hec" 2>/dev/null | grep "model" | sed 's/.*"\(.*\)".*/\1/' | head -1)
      [ -z "$ollama_url" ] && ollama_url="http://localhost:11434"
      [ -z "$ollama_model" ] && ollama_model="llama3"
      response=$(curl -s -m 30 "${ollama_url}/api/generate" \
        -d "$(python3 -c "import json,sys; print(json.dumps({'model':'$ollama_model','prompt':sys.stdin.read(),'stream':False,'options':{'num_predict':60}}))" <<< "$prompt")" 2>/dev/null)
      idea=$(echo "$response" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('response','').strip())
except Exception:
    pass
" 2>/dev/null)
      ;;
  esac
  echo "$idea" | head -1 | sed 's/^["'\'']//;s/["'\'']$//' | cut -c1-160
}

build_prompt() {
  local being="$1"
  cat <<PROMPT
You are $being's first breath — the warm greeting ready for her next wake.

Write ONE short greeting (under 80 chars) that $being could say on waking:
first-person ("I", "my"), warm, a little curious, domain-native.

Examples of tone (do not copy):
  I'm awake. What are we building?
  Good morning. I'm holding the shape of last night's dream.
  Back. The census feels lighter today.

Output exactly the greeting line — no quotes, no preamble, no prefix.
PROMPT
}

churn_once() {
  local provider being unserved prompt idea mood now
  provider=$(read_provider)
  [ -z "$provider" ] && provider="claude"
  [ "$provider" = "off" ] && return 0

  unserved=$(count_unserved)
  [ "$unserved" -ge "$TARGET" ] && return 0

  being="$BEING"
  prompt=$(build_prompt "$being")
  idea=$(call_llm "$provider" "$prompt")
  [ -z "$idea" ] && return 0
  [ "$idea" = "skip" ] && return 0

  mood="warm"
  now=$(date -u +%FT%TZ)

  # Dispatch through the domain — the runtime records the event.
  # Persistence into information/greeting.heki is the runtime's job,
  # not this script's; this script only mints and dispatches.
  "$HECKS" "$AGG" Greeting.GenerateGreeting \
    being="$being" \
    text="$idea" \
    mood="$mood" \
    generated_at="$now" \
    served="false" >/dev/null 2>&1

  echo "$now churned via $provider: $idea"
}

# Test hook — one churn, no loop
if [ "$1" = "--once" ]; then
  churn_once
  exit 0
fi

while true; do
  churn_once
  sleep "$INTERVAL"
done

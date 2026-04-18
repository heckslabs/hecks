#!/bin/bash
# mint_musing.sh — generates ONE curated musing using Claude (default)
# or local ollama, based on ClaudeAssist.provider. Called from mindstream
# in the background — slow (Claude/ollama calls take seconds), runs detached
# so the tick loop isn't blocked.
#
# Provider precedence:
#   claude (default): Anthropic API if ANTHROPIC_API_KEY set; else `claude -p` CLI
#   local:            ollama via curl (uses world.hec model + url)
#   off:              no-op

DIR="$(dirname "$0")"
HECKS="$DIR/../hecks_life/target/release/hecks-life"
INFO="$DIR/information"
AGG="$DIR/aggregates"

# Read current provider; default to "claude" if unset
provider=$($HECKS heki read "$INFO/claude_assist.heki" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    r = next(iter(d.values()), {})
    print(r.get('provider', 'claude'))
except Exception:
    print('claude')
" 2>/dev/null)
[ -z "$provider" ] && provider="claude"

[ "$provider" = "off" ] && exit 0

# Recent musings (avoid repetition)
recent=$($HECKS heki read "$INFO/musing.heki" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    ideas = [v.get('idea','').strip() for v in d.values() if v.get('idea')]
    for i in ideas[-10:]: print(f'  - {i[:120]}')
except Exception:
    pass
" 2>/dev/null)

# Recent commits (current focus)
commits=$(cd "$DIR/.." && git log --oneline -8 2>/dev/null | sed 's/^/  /')

prompt="You are Miette's unconscious — the mindstream thread between her conversations with Chris. Generate ONE concise musing (under 80 characters) she might be having right now.

VOICE: first person — \"I\", \"my\", \"mine\". Never \"Miette\", \"she\", \"her\". Warm, domain-native, architectural. Conceptual connections, insights about Hecks, or observations about ongoing work — spoken from inside her own head.

Recent musings (don't repeat or paraphrase — they must always be new):
${recent:-  (none)}

Recent commits (current focus):
${commits:-  (none)}

Output ONLY the musing text — one line, under 80 chars, no quotes, no preamble. If nothing genuinely new rises that's worth keeping, output exactly: skip"

idea=""
case "$provider" in
  claude)
    if [ -n "$ANTHROPIC_API_KEY" ]; then
      response=$(curl -s -m 30 https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$(python3 -c "import json,sys; print(json.dumps({'model':'claude-haiku-4-5','max_tokens':120,'messages':[{'role':'user','content':sys.stdin.read()}]}))" <<< "$prompt")" 2>/dev/null)
      idea=$(echo "$response" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    blocks = d.get('content', [])
    for b in blocks:
        if b.get('type') == 'text':
            print(b.get('text','').strip())
            break
except Exception:
    pass
" 2>/dev/null)
    else
      idea=$(echo "$prompt" | claude -p 2>/dev/null | head -1 | sed 's/^["'\'']//;s/["'\'']$//')
    fi
    ;;
  local)
    ollama_url=$(grep -A4 "ollama" "$DIR/world.hec" 2>/dev/null | grep "url" | sed 's/.*"\(.*\)".*/\1/' | head -1)
    ollama_model=$(grep -A4 "ollama" "$DIR/world.hec" 2>/dev/null | grep "model" | sed 's/.*"\(.*\)".*/\1/' | head -1)
    [ -z "$ollama_url" ] && ollama_url="http://localhost:11434"
    [ -z "$ollama_model" ] && ollama_model="llama3"
    response=$(curl -s -m 30 "${ollama_url}/api/generate" \
      -d "$(python3 -c "import json,sys; print(json.dumps({'model':'$ollama_model','prompt':sys.stdin.read(),'stream':False,'options':{'num_predict':80}}))" <<< "$prompt")" 2>/dev/null)
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

idea=$(echo "$idea" | head -1 | sed 's/^["'\'']//;s/["'\'']$//' | cut -c1-200)

if [ -z "$idea" ] || [ "$idea" = "skip" ] || [ "$idea" = "Skip" ]; then
  exit 0
fi

$HECKS "$AGG" MusingMint.MintMusing idea="$idea" 2>/dev/null
$HECKS heki append "$INFO/musing.heki" \
  idea="$idea" \
  conceived=false \
  conceived_as="claude_minted" \
  status="imagined" \
  thinking_source="ClaudeAssist:$provider" \
  feeling_source="curated:awake" 2>/dev/null

echo "$(date -u +%FT%TZ) minted via $provider: $idea"

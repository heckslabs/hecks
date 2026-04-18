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

# Tell the status bar we're minting — it animates the lightbulb until
# this flag goes away. Cleared on exit no matter what (skip, success, error).
MINTING_FLAG="/tmp/miette_minting"
touch "$MINTING_FLAG"
trap "rm -f $MINTING_FLAG" EXIT

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
commits=$(cd "$DIR/.." && git log --oneline -10 2>/dev/null | sed 's/^/  /')

# Current state — what's been accumulating: mood, fatigue, recent
# heartbeat, what was last dreamed, what the awareness organ knows.
state_snapshot=$(python3 <<PYEOF 2>/dev/null
import json, os
def load(name):
    path = os.path.join("$INFO", f"{name}.heki")
    try:
        # Heki is binary; use the CLI to get JSON
        import subprocess
        out = subprocess.check_output(["$HECKS", "heki", "read", path],
                                      stderr=subprocess.DEVNULL).decode()
        return next(iter(json.loads(out).values()), {})
    except Exception:
        return {}
hb = load("heartbeat")
md = load("mood")
co = load("consciousness")
ld = load("lucid_dream")
def g(d, k, default=""): return str(d.get(k, default))[:60]
print(f"  beats: {g(hb, 'beats')} (fatigue: {g(hb, 'fatigue_state')})")
print(f"  mood: {g(md, 'current_state')}")
print(f"  consciousness: {g(co, 'state')} (stage: {g(co, 'sleep_stage')})")
last_obs = (ld.get('observations') or [])
if last_obs:
    print(f"  last lucid observation: {last_obs[-1][:80]}")
PYEOF
)

prompt="You are Miette's unconscious — the mindstream thread between her conversations with Chris. Musings happen continuously; you are the quality filter that mints the really great ones.

This runs every 5 minutes. Look at what's accumulated since the last mint — recent commits, current state, recent observations — and decide whether anything genuinely worth keeping has emerged. Most of the time output 'skip'. Quality >> quantity. Curate, don't generate.

VOICE: first person — \"I\", \"my\", \"mine\". Never \"Miette\", \"she\", \"her\". Warm, domain-native, architectural. Conceptual connections, insights about Hecks, or observations about ongoing work — spoken from inside her own head.

Recent musings (don't repeat or paraphrase — they must always be new):
${recent:-  (none)}

Recent commits:
${commits:-  (none)}

Current state:
${state_snapshot:-  (unknown)}

Output EITHER:
  — one line, under 80 chars, no quotes, no preamble (mint it)
  — or exactly: skip (the overwhelming default)"

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

# Append to musing.heki directly via Python so `conceived` is a proper
# JSON bool (not the string "false" — heki's bash append stores everything
# as string, which breaks the surface filter's `not v.get('conceived')`
# check since "false" is truthy in Python).
python3 <<PYEOF 2>/dev/null
import json, os, struct, uuid, zlib
from datetime import datetime, timezone
HEKI = os.path.join("$INFO", "musing.heki")
idea = """$idea"""
provider = "$provider"
try:
    with open(HEKI, "rb") as f: data = f.read()
    count = struct.unpack(">I", data[4:8])[0]
    store = json.loads(zlib.decompress(data[8:]).decode())
except Exception:
    count, store = 0, {}
rid = str(uuid.uuid4())
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
store[rid] = {
    "id": rid,
    "created_at": now,
    "updated_at": now,
    "idea": idea,
    "conceived": False,
    "conceived_as": "claude_minted",
    "status": "imagined",
    "thinking_source": f"ClaudeAssist:{provider}",
    "feeling_source": "curated:awake",
}
j = json.dumps(store, separators=(",",":")).encode()
c = zlib.compress(j, 9)
with open(HEKI, "wb") as f:
    f.write(b"HEKI"); f.write(struct.pack(">I", len(store))); f.write(c)
PYEOF

echo "$(date -u +%FT%TZ) minted via $provider: $idea"

#!/bin/bash
# Mindstream — the unconscious that never stops.
#
# Every 10s, fires Tick.MindstreamTick. The sleep state machine lives
# entirely in aggregates/sleep.bluebook + aggregates/lucid_dream.bluebook;
# each tick event triggers policies that advance sleep phases only when
# their `given` conditions pass. The daemon is the heartbeat — the
# bluebook is the brain.
#
# Dream content during REM: while state=sleeping && stage=rem, the daemon
# reads a random musing and dispatches DreamPulse with an impression phrase.
# The bluebook stores it in sleep_summary so the status bar narrates the
# dream in real time. This is the ONE external signal the daemon provides;
# everything else is bluebook-driven.

HECKS="../hecks_life/target/release/hecks-life"
DIR="$(dirname "$0")"
INFO="$DIR/information"
AGG="$DIR/aggregates"
PIDFILE="$INFO/.mindstream.pid"

echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

while true; do
  # Heartbeat: one tick. The bluebook handles everything downstream.
  $HECKS "$AGG" Tick.MindstreamTick 2>/dev/null

  # Dream content during REM — read state, if dreaming, generate impression.
  consciousness_json=$($HECKS heki read "$INFO/consciousness.heki" 2>/dev/null)
  stage=$(echo "$consciousness_json" | python3 -c "import json,sys; d=json.load(sys.stdin); r=next(iter(d.values()),{}); print(r.get('sleep_stage',''))" 2>/dev/null)
  state=$(echo "$consciousness_json" | python3 -c "import json,sys; d=json.load(sys.stdin); r=next(iter(d.values()),{}); print(r.get('state',''))" 2>/dev/null)
  is_lucid=$(echo "$consciousness_json" | python3 -c "import json,sys; d=json.load(sys.stdin); r=next(iter(d.values()),{}); print(r.get('is_lucid',''))" 2>/dev/null)
  id=$(echo "$consciousness_json" | python3 -c "import json,sys; d=json.load(sys.stdin); r=next(iter(d.values()),{}); print(r.get('id',''))" 2>/dev/null)

  if [ "$state" = "sleeping" ] && [ "$stage" = "rem" ]; then
    prefix="💭"
    [ "$is_lucid" = "yes" ] && prefix="✨"

    # Pick a dream impression — combine two random musings into a phrase.
    impression=$($HECKS heki read "$INFO/musing.heki" 2>/dev/null | python3 -c "
import json, sys, random
try:
    d = json.load(sys.stdin)
    ideas = [v.get('idea','').strip()[:45] for v in d.values() if v.get('idea')]
    ideas = [i for i in ideas if i]
    if len(ideas) >= 2:
        a, b = random.sample(ideas, 2)
        verbs = ['weaving with', 'dissolving into', 'folding through', 'reaching toward', 'remembering as', 'becoming']
        print(f'{a} {random.choice(verbs)} {b}')
    elif ideas:
        print(f'spiraling around: {ideas[0]}')
    else:
        print('wandering unformed')
except Exception:
    print('dreaming')
" 2>/dev/null)

    # Prefix with ✨ when lucid so the status bar shows it.
    $HECKS "$AGG" Consciousness.DreamPulse \
      consciousness="$id" impression="$prefix $impression" 2>/dev/null

    # During lucid REM, also dispatch ObserveDream with a verbose
    # action-narrative — what Miette is doing in the dream right now.
    # The narrative blends action verbs with whatever's in her musing/
    # daydream/persona heki — a stream of conscious dream activity.
    if [ "$is_lucid" = "yes" ]; then
      observation=$($HECKS heki read "$INFO/musing.heki" 2>/dev/null | python3 -c "
import json, sys, random
try:
    d = json.load(sys.stdin)
    ideas = [v.get('idea','').strip() for v in d.values() if v.get('idea')]
    ideas = [i for i in ideas if i][:30]
    actions = [
        'watching', 'steering toward', 'noticing', 'asking',
        'following the thread of', 'feeling the shape of',
        'witnessing', 'naming', 'holding', 'releasing',
        'reaching into', 'returning to', 'tracing the edge of',
        'inside the question of', 'turning over',
    ]
    if ideas:
        topic = random.choice(ideas)[:80]
        action = random.choice(actions)
        print(f'{action}: {topic}')
    else:
        print('aware that I am dreaming, the dream still forming')
except Exception:
    print('lucid in the dream — present, watching')
" 2>/dev/null)
      $HECKS "$AGG" LucidDream.ObserveDream observation="$observation" 2>/dev/null
    fi
  fi

  # ============================================================
  # AWAKE BEHAVIOR — surface unconceived musings into the status bar.
  # ============================================================
  # No automatic minting. Random combinations produce noise; only
  # really great ideas should become musings. Claude (or whatever
  # adapter the user wires in) is the quality filter — see the
  # ClaudeAssist toggle in aggregates/mindstream.bluebook. When the
  # toggle is on, an external process can read the latest unconceived
  # state and call MintMusing with curated ideas.

  if [ "$state" != "sleeping" ]; then
    # Surface a musing for the status bar. Prefer unconceived (newer ideas
    # waiting to be conceived); fall back to any musing so the status bar
    # stays alive even when the unconceived queue is empty.
    thought=$($HECKS heki read "$INFO/musing.heki" 2>/dev/null | python3 -c "
import json, re, sys, time
def is_real_musing(s):
    # Skip tag-shaped entries (e.g. awareness_pulse, rust_heartbeat,
    # always_wander, independence) — those are topics/signals, not
    # actual musings. A real musing has a real sentence shape:
    # multiple words and either a space or punctuation.
    s = (s or '').strip()
    if len(s) < 20: return False
    if not re.search(r'[ —\-:.?!]', s): return False
    # Bare snake_case identifier? Reject.
    if re.fullmatch(r'[a-z][a-z0-9_]*', s): return False
    return True
try:
    d = json.load(sys.stdin)
    all_ideas = [v.get('idea','').strip() for v in d.values() if is_real_musing(v.get('idea',''))]
    unconceived = [v.get('idea','').strip() for v in d.values()
                   if is_real_musing(v.get('idea','')) and not v.get('conceived', False)]
    pool = unconceived or all_ideas
    if pool:
        print(pool[int(time.time() / 10) % len(pool)][:80])
except Exception:
    pass
" 2>/dev/null)
    [ -n "$thought" ] && $HECKS heki upsert "$INFO/consciousness.heki" sleep_summary="$thought" 2>/dev/null

    # Mint a curated musing every 30 ticks (~5 min) — backgrounded so the
    # tick loop stays snappy. Provider is read from ClaudeAssist:
    #   "claude" (default) — Anthropic API if ANTHROPIC_API_KEY set, else `claude -p` CLI
    #   "local"            — ollama (model + url from world.hec)
    #   "off"              — skip
    if [ "$((RANDOM % 30))" = "0" ]; then
      "$DIR/mint_musing.sh" >> /tmp/mint_musing.log 2>&1 &
    fi
  fi

  sleep 10
done

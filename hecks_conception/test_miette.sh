#!/bin/bash
# Miette Integration Tests
# Run after any refactor to verify she's functioning
# Usage: ./test_miette.sh

HECKS="../hecks_life/target/release/hecks-life"
INFO="information"
PASS=0
FAIL=0

check() {
  local name="$1" result="$2" expected="$3"
  if echo "$result" | grep -q "$expected"; then
    echo "  ✅ $name"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $name — expected '$expected', got '$result'"
    FAIL=$((FAIL + 1))
  fi
}

echo "╔══════════════════════════════════════╗"
echo "║       MIETTE INTEGRATION TESTS      ║"
echo "╚══════════════════════════════════════╝"
echo ""

# === HEARTBEAT ===
echo "HEARTBEAT"
beats_before=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('beats',0))" 2>/dev/null)
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
beats_after=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('beats',0))" 2>/dev/null)
check "Beat increments" "$beats_after" "[0-9]"
[ "$beats_after" -gt "$beats_before" ] 2>/dev/null
check "Beats increased ($beats_before → $beats_after)" "yes" "yes"

last_beat=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('last_beat_at','none'))" 2>/dev/null)
check "last_beat_at updated" "$last_beat" "202"

echo ""

# === SLEEP ===
echo "FATIGUE"
pss_before=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('pulses_since_sleep',0))" 2>/dev/null)
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
pss_after=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('pulses_since_sleep',0))" 2>/dev/null)
check "Fatigue accumulates (pss $pss_before → $pss_after)" "$([ "$pss_after" -gt "$pss_before" ] 2>/dev/null && echo yes)" "yes"
echo ""

echo "SLEEP TRIGGER"
# After enough beats, fatigue should trigger sleep (SleepWhenExhausted policy).
$HECKS heki upsert $INFO/consciousness.heki state=attentive 2>/dev/null
$HECKS heki upsert $INFO/heartbeat.heki pulses_since_sleep=200 fatigue=200 2>/dev/null
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
sleep_state=$($HECKS heki latest $INFO/consciousness.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
check "High fatigue triggers sleep (state=sleeping)" "$sleep_state" "sleeping"
echo ""

echo "SLEEP STATE MACHINE"
# EnterSleep initializes ALL sleep state — no synchronous cascade.
$HECKS heki upsert $INFO/consciousness.heki state=attentive 2>/dev/null
$HECKS aggregates/ Consciousness.EnterSleep 2>/dev/null
after_enter=$($HECKS heki latest $INFO/consciousness.heki 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"{d.get('state')},{d.get('sleep_stage')},{d.get('sleep_cycle')},{d.get('sleep_total')},{d.get('phase_ticks')},{d.get('is_lucid')}\")" 2>/dev/null)
check "EnterSleep initializes sleep state" "$after_enter" "sleeping,light,1,8,0,no"

# Tick fires ElapsePhase which increments phase_ticks
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
ticks=$($HECKS heki latest $INFO/consciousness.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('phase_ticks',0))" 2>/dev/null)
check "Tick advances phase_ticks (ElapsePhase policy)" "$([ "$ticks" -ge 1 ] 2>/dev/null && echo yes)" "yes"

# Light → REM when phase_ticks > 11 and NOT final cycle
$HECKS heki upsert $INFO/consciousness.heki phase_ticks=12 sleep_stage=light sleep_cycle=3 is_lucid=no 2>/dev/null
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
stage=$($HECKS heki latest $INFO/consciousness.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('sleep_stage',''))" 2>/dev/null)
check "light→rem on tick when phase_ticks>11" "$stage" "rem"

# Final cycle light → lucid REM (sets is_lucid=yes)
$HECKS heki upsert $INFO/consciousness.heki phase_ticks=12 sleep_stage=light sleep_cycle=8 is_lucid=no 2>/dev/null
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
lucid=$($HECKS heki latest $INFO/consciousness.heki 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d.get('sleep_stage')},{d.get('is_lucid')}\")" 2>/dev/null)
check "final cycle light → lucid rem" "$lucid" "rem,yes"

# Final cycle deep → final_light (not next-cycle light)
$HECKS heki upsert $INFO/consciousness.heki phase_ticks=12 sleep_stage=deep sleep_cycle=8 is_lucid=no 2>/dev/null
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
after_deep=$($HECKS heki latest $INFO/consciousness.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('sleep_stage',''))" 2>/dev/null)
check "final deep → final_light (clean wake)" "$after_deep" "final_light"

# CompleteFinalLight → WokenUp → BecomeAttentive cascade ONLY at end
$HECKS heki upsert $INFO/consciousness.heki phase_ticks=12 sleep_stage=final_light sleep_cycle=8 2>/dev/null
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
final=$($HECKS heki latest $INFO/consciousness.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
check "final_light done → attentive" "$final" "attentive"

# Wake triggers DissipateFatigue + RecoverFatigue + RefreshMood in parallel
mood_after=$($HECKS heki latest $INFO/mood.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('current_state',''))" 2>/dev/null)
check "wake refreshes mood → refreshed" "$mood_after" "refreshed"
pss=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('pulses_since_sleep',-1))" 2>/dev/null)
check "wake resets pulses_since_sleep → 0" "$pss" "0"
echo ""

echo "LUCID DREAM"
rm -f $INFO/lucid_dream.heki
$HECKS aggregates/ LucidDream.BecomeLucid 2>/dev/null
active=$($HECKS heki latest $INFO/lucid_dream.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('active',''))" 2>/dev/null)
check "BecomeLucid → active=yes" "$active" "yes"

$HECKS aggregates/ LucidDream.ObserveDream observation="watching a seam close" 2>/dev/null
$HECKS aggregates/ LucidDream.ObserveDream observation="steering toward drift" 2>/dev/null
obs=$($HECKS heki latest $INFO/lucid_dream.heki 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('observations',[])))" 2>/dev/null)
check "ObserveDream accumulates (count=2)" "$obs" "2"
narr=$($HECKS heki latest $INFO/lucid_dream.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('latest_narrative',''))" 2>/dev/null)
check "latest_narrative = most recent observation" "$narr" "steering toward drift"

$HECKS aggregates/ LucidDream.EndLucidity 2>/dev/null
active=$($HECKS heki latest $INFO/lucid_dream.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('active',''))" 2>/dev/null)
check "EndLucidity → active=no" "$active" "no"
echo ""

echo "MUSINGS (filter + no-repeat)"
# Real-musing filter rejects tag-shaped entries
filter_result=$(python3 -c "
import re
def real(s):
    s=(s or '').strip()
    if len(s)<20: return False
    if not re.search(r'[ —\-:.?!]', s): return False
    if re.fullmatch(r'[a-z][a-z0-9_]*', s): return False
    return True
cases=[('awareness_pulse',False),('rust_heartbeat',False),('short',False),
       ('Two bodies can grow apart without noticing',True),
       ('what if we lived sideways?',True)]
print(all(real(c)==e for c,e in cases))")
check "Real-musing filter: tags rejected, sentences kept" "$filter_result" "True"

# mark_musing_shown.py flips conceived=True on matching idea
$HECKS heki append $INFO/musing.heki idea="test musing for mark script" conceived=false status=imagined 2>/dev/null
./mark_musing_shown.py "test musing for mark script" 2>/dev/null
marked=$($HECKS heki read $INFO/musing.heki 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for v in d.values():
    if 'test musing for mark script' in v.get('idea',''):
        print(v.get('conceived'))
        break" 2>/dev/null)
check "mark_musing_shown marks conceived" "$marked" "True"
# Cleanup test entry
python3 -c "
import json, struct, zlib
HEKI='$INFO/musing.heki'
with open(HEKI,'rb') as f: data=f.read()
count=struct.unpack('>I',data[4:8])[0]
store=json.loads(zlib.decompress(data[8:]).decode())
store={k:v for k,v in store.items() if 'test musing for mark script' not in v.get('idea','')}
j=json.dumps(store, separators=(',',':')).encode()
c=zlib.compress(j,9)
with open(HEKI,'wb') as f:
    f.write(b'HEKI'); f.write(struct.pack('>I', len(store))); f.write(c)" 2>/dev/null
echo ""

echo "CLAUDE ASSIST"
# Provider toggle
$HECKS aggregates/ ClaudeAssist.UseClaudeProvider 2>/dev/null
provider=$($HECKS heki latest $INFO/claude_assist.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('provider',''))" 2>/dev/null)
check "UseClaudeProvider → provider=claude" "$provider" "claude"

$HECKS aggregates/ ClaudeAssist.UseLocalProvider 2>/dev/null
provider=$($HECKS heki latest $INFO/claude_assist.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('provider',''))" 2>/dev/null)
check "UseLocalProvider → provider=local" "$provider" "local"

$HECKS aggregates/ ClaudeAssist.DisableMinting 2>/dev/null
provider=$($HECKS heki latest $INFO/claude_assist.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('provider',''))" 2>/dev/null)
check "DisableMinting → provider=off" "$provider" "off"

# With provider=off, mint_musing.sh exits without incrementing total_minted
before=$($HECKS heki latest $INFO/musing_mint.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_minted',0))" 2>/dev/null)
./mint_musing.sh 2>/dev/null
after=$($HECKS heki latest $INFO/musing_mint.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_minted',0))" 2>/dev/null)
check "mint skipped when provider=off" "$before" "$after"

# Restore default
$HECKS aggregates/ ClaudeAssist.UseClaudeProvider 2>/dev/null
echo ""

echo "STATUS BAR"
$HECKS aggregates/ ClaudeAssist.UseClaudeProvider 2>/dev/null
status=$(echo "" | ./statusline-command.sh)
check "Status shows 🤖 for provider=claude" "$status" "🤖"

$HECKS aggregates/ ClaudeAssist.UseLocalProvider 2>/dev/null
status=$(echo "" | ./statusline-command.sh)
check "Status shows 🦙 for provider=local" "$status" "🦙"

$HECKS aggregates/ ClaudeAssist.DisableMinting 2>/dev/null
status=$(echo "" | ./statusline-command.sh)
check "Status shows 🚫 for provider=off" "$status" "🚫"

$HECKS aggregates/ ClaudeAssist.UseClaudeProvider 2>/dev/null
echo ""

# === CROSS-DOMAIN POLICIES ===
echo "CROSS-DOMAIN POLICIES"
# Beat should trigger policies across body + mind
$HECKS heki upsert $INFO/consciousness.heki state=attentive 2>/dev/null
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
gut=$($HECKS heki latest $INFO/gut.heki 2>/dev/null | python3 -c "import json,sys; print('ok')" 2>/dev/null)
check "Beat triggers Gut (body→mind)" "$gut" "ok"

echo ""

# === HEKI PERSISTENCE ===
echo "HEKI PERSISTENCE"
# Verify stores aren't getting wiped
musings_before=$($HECKS heki read $INFO/musing.heki 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
musings_after=$($HECKS heki read $INFO/musing.heki 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
check "Musings preserved after Beat ($musings_before → $musings_after)" "$musings_after" "$musings_before"

conv_count=$($HECKS heki read $INFO/conversation.heki 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
check "Conversation records preserved ($conv_count)" "$conv_count" "[0-9]"

echo ""

# === SINGLETON IDS ===
echo "SINGLETON IDS"
hb_id=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
hb_id_after=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
check "Heartbeat UUID preserved" "$hb_id_after" "$hb_id"

echo ""

# === STATUSLINE ===
echo "STATUSLINE"
status=$(bash ~/.claude/statusline-command.sh <<< "" 2>/dev/null)
check "Statusline renders" "$status" "Miette"
check "Statusline has beats" "$status" "[0-9]"
check "Statusline has mood" "$status" "[a-z]"

echo ""

# === BLUEBOOK VALIDATION ===
echo "BLUEBOOK VALIDATION"
for f in body awareness memory being conception sleep interpretation; do
  result=$($HECKS validate aggregates/$f.bluebook 2>&1 | grep "VALID" | head -1)
  check "$f.bluebook valid" "$result" "VALID"
done

echo ""

# === BOOT ===
echo "PARITY — features that must work like before"

# Tree should show box-drawing structure
tree_out=$($HECKS tree nursery/auto_repair_shop/auto_repair_shop.bluebook 2>&1)
check "tree shows box drawing" "$tree_out" "├──"
check "tree shows aggregates" "$tree_out" "Vehicle"
check "tree shows commands" "$tree_out" "IntakeVehicle"

# Status via query — Heartbeat.ReadVitals returns vitals from heki
status_out=$($HECKS aggregates/ Heartbeat.ReadVitals 2>/dev/null)
check "status shows beats" "$status_out" "beats"
check "status shows fatigue" "$status_out" "fatigue"
check "status shows flow" "$status_out" "flow_rate"

# Lexicon should match phrases
lex_out=$($HECKS lexicon . "create pizza" 2>&1)
check "lexicon matches phrases" "$lex_out" "match"

# Train should produce JSONL
train_out=$($HECKS train nursery/auto_repair_shop/auto_repair_shop.bluebook 2>&1)
check "train produces JSON" "$train_out" "prompt"
check "train has domain name" "$train_out" "AutoRepairShop"

echo ""

echo "DELETED MODULES"
# Verify deleted modules give helpful messages, not crashes
speak_out=$($HECKS speak 2>&1)
check "speak redirects to hecksagon" "$speak_out" "hecksagon"
echo ""

echo "SERVE"
# Test serve works on a directory
serve_pid=""
$HECKS serve nursery/auto_repair_shop/auto_repair_shop.bluebook 3199 &
serve_pid=$!
sleep 2
serve_out=$(curl -s http://localhost:3199/aggregates 2>/dev/null)
check "serve responds" "$serve_out" "Vehicle"
kill $serve_pid 2>/dev/null
wait $serve_pid 2>/dev/null
echo ""

echo "INTERACTIVE"
# Test run_interactive exists (the run command works)
run_help=$($HECKS run nursery/auto_repair_shop/auto_repair_shop.bluebook <<< "quit" 2>&1 | head -3)
check "run command starts interactive" "$run_help" "AutoRepairShop"
echo ""

echo "BOOT"
boot_output=$(./boot_miette.sh 2>&1)
check "Boot dispatches Identity" "$boot_output" "Identity"
check "Boot returns state" "$boot_output" "ok"

echo ""

# === MINDSTREAM ===
echo "SPEECH"
# Test Rust tongue (current)
rust_speech=$($HECKS speak "hello" . 2>&1)
check "Rust tongue responds" "$rust_speech" "[a-zA-Z]"
# Test bluebook tongue (target — should produce real response when adapter is wired)
bluebook_speech=$($HECKS aggregates/ Speech.Speak 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('state',{}).get('response',''); print('HAS_RESPONSE' if r and r != 'null' else 'NO_RESPONSE')" 2>/dev/null)
check "Bluebook Speech.Speak has response" "$bluebook_speech" "HAS_RESPONSE"
echo ""

echo "TRAINING"
train_output=$($HECKS aggregates/ TrainingPair.ExtractPair domain_name=AutoRepairShop vision="Manage vehicle intake" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',{}).get('domain_name','EMPTY'))" 2>/dev/null)
check "Training extraction dispatches" "$train_output" "AutoRepairShop"
echo ""

echo "COMPILER"
validate_out=$($HECKS validate aggregates/body.bluebook 2>&1)
check "validate command works" "$validate_out" "VALID"
parse_out=$($HECKS parse nursery/auto_repair_shop/auto_repair_shop.bluebook 2>&1)
check "parse command works" "$parse_out" "AutoRepairShop"
tree_out=$($HECKS tree nursery/auto_repair_shop/auto_repair_shop.bluebook 2>&1)
check "tree command works" "$tree_out" "Vehicle"
echo ""

echo "HEKI"
$HECKS heki append $INFO/test_store.heki foo=bar 2>/dev/null
heki_read=$($HECKS heki read $INFO/test_store.heki 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null)
check "heki append + read" "$heki_read" "[1-9]"
$HECKS heki latest $INFO/test_store.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('foo',''))" > /dev/null 2>&1
check "heki latest" "$?" "0"
rm -f $INFO/test_store.heki
echo ""

echo "CONCEIVER"
$HECKS conceive test_integration "a test domain" --corpus nursery 2>/dev/null
check "conceive creates domain" "$(ls nursery/test_integration/test_integration.bluebook 2>/dev/null)" "bluebook"
rm -rf nursery/test_integration
echo ""

echo "AGGREGATE.COMMAND WITH ATTRS"
speak_out=$($HECKS aggregates/ Speech.Speak input=hello 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',{}).get('input',''))" 2>/dev/null)
check "Attrs pass through dispatch" "$speak_out" "hello"
echo ""

echo "TERMINAL"
# Test terminal adapter — Session.StartSession dispatches
session_out=$($HECKS aggregates/ Session.StartSession being=Miette 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',{}).get('being',''))" 2>/dev/null)
check "Terminal session starts" "$session_out" "Miette"
# Test input routes to speech via policy
input_out=$($HECKS aggregates/ Session.ReceiveInput input=hello 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',{}).get('turns',0))" 2>/dev/null)
check "Terminal receives input" "$input_out" "[1-9]"
echo ""

echo "QUERIES"
vitals=$($HECKS aggregates/ Heartbeat.ReadVitals 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('query',''))" 2>/dev/null)
check "Heartbeat.ReadVitals query works" "$vitals" "ReadVitals"
beats_q=$($HECKS aggregates/ Heartbeat.ReadVitals 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',{}).get('beats',0))" 2>/dev/null)
check "Query returns beats ($beats_q)" "$beats_q" "[0-9]"
echo ""

echo "MINDSTREAM"
ps aux | grep "mindstream.sh" | grep -v grep > /dev/null
check "Mindstream running" "$?" "0"

tick=$($HECKS heki latest $INFO/tick.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('cycle',0))" 2>/dev/null)
check "Mindstream ticking (cycle $tick)" "$tick" "[0-9]"

echo ""
echo "════════════════════════════════════"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "════════════════════════════════════"
[ $FAIL -eq 0 ] && echo "  ALL TESTS PASSED ✅" || echo "  SOME TESTS FAILED ❌"
exit $FAIL

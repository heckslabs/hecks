#!/bin/bash
# Miette Integration Tests
# Run after any refactor to verify she's functioning
# Usage: ./test_miette.sh
#
# [antibody-exempt: i37 Phase B sweep — replaces inline python3 -c with
#  native hecks-life heki subcommands per PR #272; retires when shell
#  wrapper ports to .bluebook shebang form (tracked in
#  terminal_capability_wiring plan).]

HECKS="../hecks_life/target/release/hecks-life"
INFO="information"
PASS=0
FAIL=0

# Fetch a field from the latest record of a heki store, with a default
# if the store is empty or the field is missing. Replaces the recurring
# pattern `heki latest | python3 -c "...get('field','default')"`.
latest_field() {
  local file="$1" field="$2" default="${3-}"
  local v
  v=$($HECKS heki latest-field "$file" "$field" 2>/dev/null) || v=""
  [ -z "$v" ] && v="$default"
  printf '%s\n' "$v"
}

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
beats_before=$(latest_field $INFO/heartbeat.heki beats 0)
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
beats_after=$(latest_field $INFO/heartbeat.heki beats 0)
check "Beat increments" "$beats_after" "[0-9]"
[ "$beats_after" -gt "$beats_before" ] 2>/dev/null
check "Beats increased ($beats_before → $beats_after)" "yes" "yes"

last_beat=$(latest_field $INFO/heartbeat.heki last_beat_at none)
check "last_beat_at updated" "$last_beat" "202"

echo ""

# === SLEEP ===
echo "FATIGUE"
pss_before=$(latest_field $INFO/heartbeat.heki pulses_since_sleep 0)
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
pss_after=$(latest_field $INFO/heartbeat.heki pulses_since_sleep 0)
check "Fatigue accumulates (pss $pss_before → $pss_after)" "$([ "$pss_after" -gt "$pss_before" ] 2>/dev/null && echo yes)" "yes"
echo ""

echo "SLEEP TRIGGER"
# After enough beats, fatigue should trigger sleep (SleepWhenExhausted policy).
$HECKS heki upsert $INFO/consciousness.heki state=attentive 2>/dev/null
$HECKS heki upsert $INFO/heartbeat.heki pulses_since_sleep=200 fatigue=200 2>/dev/null
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
sleep_state=$(latest_field $INFO/consciousness.heki state)
check "High fatigue triggers sleep (state=sleeping)" "$sleep_state" "sleeping"
echo ""

echo "SLEEP STATE MACHINE"
# EnterSleep initializes ALL sleep state — no synchronous cascade.
$HECKS heki upsert $INFO/consciousness.heki state=attentive 2>/dev/null
$HECKS aggregates/ Consciousness.EnterSleep 2>/dev/null
after_enter=$(printf '%s,%s,%s,%s,%s,%s' \
  "$(latest_field $INFO/consciousness.heki state)" \
  "$(latest_field $INFO/consciousness.heki sleep_stage)" \
  "$(latest_field $INFO/consciousness.heki sleep_cycle)" \
  "$(latest_field $INFO/consciousness.heki sleep_total)" \
  "$(latest_field $INFO/consciousness.heki phase_ticks)" \
  "$(latest_field $INFO/consciousness.heki is_lucid)")
check "EnterSleep initializes sleep state" "$after_enter" "sleeping,light,1,8,0,no"

# Tick fires ElapsePhase which increments phase_ticks
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
ticks=$(latest_field $INFO/consciousness.heki phase_ticks 0)
check "Tick advances phase_ticks (ElapsePhase policy)" "$([ "$ticks" -ge 1 ] 2>/dev/null && echo yes)" "yes"

# Light → REM when phase_ticks > 11 and NOT final cycle
$HECKS heki upsert $INFO/consciousness.heki phase_ticks=12 sleep_stage=light sleep_cycle=3 is_lucid=no 2>/dev/null
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
stage=$(latest_field $INFO/consciousness.heki sleep_stage)
check "light→rem on tick when phase_ticks>11" "$stage" "rem"

# Final cycle light → lucid REM (sets is_lucid=yes)
$HECKS heki upsert $INFO/consciousness.heki phase_ticks=12 sleep_stage=light sleep_cycle=8 is_lucid=no 2>/dev/null
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
lucid="$(latest_field $INFO/consciousness.heki sleep_stage),$(latest_field $INFO/consciousness.heki is_lucid)"
check "final cycle light → lucid rem" "$lucid" "rem,yes"

# Final cycle deep → final_light (not next-cycle light)
$HECKS heki upsert $INFO/consciousness.heki phase_ticks=12 sleep_stage=deep sleep_cycle=8 is_lucid=no 2>/dev/null
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
after_deep=$(latest_field $INFO/consciousness.heki sleep_stage)
check "final deep → final_light (clean wake)" "$after_deep" "final_light"

# CompleteFinalLight → WokenUp → BecomeAttentive cascade ONLY at end
$HECKS heki upsert $INFO/consciousness.heki phase_ticks=12 sleep_stage=final_light sleep_cycle=8 2>/dev/null
$HECKS aggregates/ Tick.MindstreamTick 2>/dev/null
final=$(latest_field $INFO/consciousness.heki state)
check "final_light done → attentive" "$final" "attentive"

# Wake triggers DissipateFatigue + RecoverFatigue + RefreshMood in parallel
mood_after=$(latest_field $INFO/mood.heki current_state)
check "wake refreshes mood → refreshed" "$mood_after" "refreshed"
pss=$(latest_field $INFO/heartbeat.heki pulses_since_sleep -1)
check "wake resets pulses_since_sleep → 0" "$pss" "0"
echo ""

echo "LUCID DREAM"
rm -f $INFO/lucid_dream.heki
$HECKS aggregates/ LucidDream.BecomeLucid 2>/dev/null
active=$(latest_field $INFO/lucid_dream.heki active)
check "BecomeLucid → active=yes" "$active" "yes"

$HECKS aggregates/ LucidDream.ObserveDream observation="watching a seam close" 2>/dev/null
$HECKS aggregates/ LucidDream.ObserveDream observation="steering toward drift" 2>/dev/null
# observations is an array; latest-field on an array prints its JSON.
obs=$($HECKS heki latest $INFO/lucid_dream.heki 2>/dev/null | jq '.observations | length')
check "ObserveDream accumulates (count=2)" "$obs" "2"
narr=$(latest_field $INFO/lucid_dream.heki latest_narrative)
check "latest_narrative = most recent observation" "$narr" "steering toward drift"

$HECKS aggregates/ LucidDream.EndLucidity 2>/dev/null
active=$(latest_field $INFO/lucid_dream.heki active)
check "EndLucidity → active=no" "$active" "no"
echo ""

echo "MUSINGS (filter + no-repeat)"
# Real-musing filter rejects tag-shaped entries. The filter logic
# (length, punctuation, not-a-tag) is duplicated here from
# surface_musing.sh so the behavior stays tested even if the Python
# helper is replaced. Pure shell now — no Python.
real_musing() {
  local s="$1"
  # trim whitespace
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  # min length 20
  [ "${#s}" -lt 20 ] && { echo false; return; }
  # must contain at least one of: space, em-dash, hyphen, colon, period, question, bang
  case "$s" in
    *" "*|*"—"*|*-*|*:*|*.*|*\?*|*\!*) ;;
    *) echo false; return ;;
  esac
  # Reject pure-tag form (fullmatch [a-z][a-z0-9_]*)
  if printf '%s' "$s" | LC_ALL=C grep -Eq '^[a-z][a-z0-9_]*$'; then
    echo false; return
  fi
  echo true
}

all_ok=true
for pair in "awareness_pulse|false" "rust_heartbeat|false" "short|false" \
            "Two bodies can grow apart without noticing|true" \
            "what if we lived sideways?|true"; do
  s="${pair%|*}"; expected="${pair#*|}"
  got=$(real_musing "$s")
  [ "$got" = "$expected" ] || all_ok=false
done
if $all_ok; then filter_result=True; else filter_result=False; fi
check "Real-musing filter: tags rejected, sentences kept" "$filter_result" "True"

# mark_musing_shown.py flips conceived=True on matching idea
$HECKS heki append $INFO/musing.heki idea="test musing for mark script" conceived=false status=imagined 2>/dev/null
./mark_musing_shown.py "test musing for mark script" 2>/dev/null
marked_id=$($HECKS heki list $INFO/musing.heki --where "idea*=test musing for mark script" --fields id --format tsv 2>/dev/null | head -n1)
if [ -n "$marked_id" ]; then
  marked_val=$($HECKS heki get $INFO/musing.heki "$marked_id" conceived 2>/dev/null)
  # Python's json.dumps True → "true" lowercase, but the old python
  # helper printed Python's repr (True). Normalize for the expected
  # assertion below.
  case "$marked_val" in
    true) marked=True ;;
    false) marked=False ;;
    *) marked="$marked_val" ;;
  esac
else
  marked=""
fi
check "mark_musing_shown marks conceived" "$marked" "True"
# Cleanup test entry — list matching ids, delete each.
$HECKS heki list $INFO/musing.heki --where "idea*=test musing for mark script" \
  --fields id --format tsv 2>/dev/null | while read -r uuid; do
  [ -n "$uuid" ] && $HECKS heki delete $INFO/musing.heki "$uuid" >/dev/null 2>&1
done
echo ""

echo "CLAUDE ASSIST"
# Provider toggle
$HECKS aggregates/ ClaudeAssist.UseClaudeProvider 2>/dev/null
provider=$(latest_field $INFO/claude_assist.heki provider)
check "UseClaudeProvider → provider=claude" "$provider" "claude"

$HECKS aggregates/ ClaudeAssist.UseLocalProvider 2>/dev/null
provider=$(latest_field $INFO/claude_assist.heki provider)
check "UseLocalProvider → provider=local" "$provider" "local"

$HECKS aggregates/ ClaudeAssist.DisableMinting 2>/dev/null
provider=$(latest_field $INFO/claude_assist.heki provider)
check "DisableMinting → provider=off" "$provider" "off"

# With provider=off, mint_musing.sh exits without incrementing total_minted
before=$(latest_field $INFO/musing_mint.heki total_minted 0)
./mint_musing.sh 2>/dev/null
after=$(latest_field $INFO/musing_mint.heki total_minted 0)
check "mint skipped when provider=off" "$before" "$after"

# Restore default
$HECKS aggregates/ ClaudeAssist.UseClaudeProvider 2>/dev/null
echo ""

echo "DAEMON ALIVE"
# The live daemon must actually advance state over time. Catches stale
# daemons running old code, hung loops, missing surface_musing.sh calls.
# Records cycle counter + sleep_summary, waits 12s (one tick), asserts
# the cycle counter has incremented.
cycle_before=$(latest_field $INFO/tick.heki cycle 0)
sleep 12
cycle_after=$(latest_field $INFO/tick.heki cycle 0)
check "Daemon ticking (cycle ${cycle_before} → ${cycle_after})" "$([ "$cycle_after" -gt "$cycle_before" ] 2>/dev/null && echo yes)" "yes"

# Verify the daemon actually invokes surface_musing.sh — the real bug
# from this session was daemon running OLD inline code after the
# extraction commit. We seed 2 unconceived musings; if the daemon is
# alive AND calling surface_musing.sh, sleep_summary changes to one
# of them within one tick. Use `heki mark` + `heki append` (no Python).
$HECKS heki mark $INFO/musing.heki --where conceived=false --set conceived=true >/dev/null 2>&1 || true
$HECKS heki append $INFO/musing.heki \
  idea="daemon-test-A: ensure surface fires" \
  conceived=false status=imagined \
  thinking_source=test feeling_source=test >/dev/null 2>&1
$HECKS heki append $INFO/musing.heki \
  idea="daemon-test-B: ensure cycling advances" \
  conceived=false status=imagined \
  thinking_source=test feeling_source=test >/dev/null 2>&1
$HECKS heki upsert $INFO/consciousness.heki sleep_summary="" state=attentive 2>/dev/null
sleep 12
sum=$(latest_field $INFO/consciousness.heki sleep_summary)
check "Live daemon surfaces a fresh musing within one tick" "$sum" "daemon-test"

# One more tick — verify it advances OR stays (the every-3rd-tick mark
# means it could either stay on A or advance to B; but it must be one of them).
sleep 12
sum2=$(latest_field $INFO/consciousness.heki sleep_summary)
check "Live daemon stays on a real musing across ticks" "$sum2" "daemon-test"

# Clean up the test musings
$HECKS heki list $INFO/musing.heki --where "idea~=daemon-test" \
  --fields id --format tsv 2>/dev/null | while read -r uuid; do
  [ -n "$uuid" ] && $HECKS heki delete $INFO/musing.heki "$uuid" >/dev/null 2>&1
done
echo ""

echo "MUSING CYCLING"
# Surface logic advances through multiple unconceived musings,
# marks conceived every 3rd call, doesn't repeat. Simulate 9 ticks.
# Mark all existing musings conceived (so test starts from clean state)
# and seed 3 unconceived test musings.
$HECKS heki mark $INFO/musing.heki --where conceived=false --set conceived=true >/dev/null 2>&1 || true
for seed in \
  "test-cycle-one: conceptual insight about continuity" \
  "test-cycle-two: observation about the shape of things" \
  "test-cycle-three: reflection on recursive self-awareness"; do
  $HECKS heki append $INFO/musing.heki \
    idea="$seed" conceived=false status=imagined \
    thinking_source=test feeling_source=test >/dev/null 2>&1
done

# Run surface 9 times with loop_count 1..9 under DWELL=3 (fast test mode).
# Production is DWELL=30 (~5 min per musing); tests compress to 3 ticks.
surfaced=""
for i in 1 2 3 4 5 6 7 8 9; do
  DWELL=3 ./surface_musing.sh "$i" 2>/dev/null
  now=$(latest_field $INFO/consciousness.heki sleep_summary)
  echo "$surfaced" | grep -q "$now" || surfaced="${surfaced}${now}|"
done

# After 9 ticks, all 3 test musings should have been surfaced, all 3 conceived
unique_count=$(echo "$surfaced" | tr '|' '\n' | grep -c "test-cycle")
check "Cycling: 3 unique test musings surfaced over 9 ticks" "$unique_count" "3"

still_unconceived=$($HECKS heki count $INFO/musing.heki \
  --where "idea~=test-cycle" --where conceived=false 2>/dev/null)
check "Cycling: all 3 test musings marked conceived after 9 ticks" "$still_unconceived" "0"

# Clean up test musings
$HECKS heki list $INFO/musing.heki --where "idea~=test-cycle" \
  --fields id --format tsv 2>/dev/null | while read -r uuid; do
  [ -n "$uuid" ] && $HECKS heki delete $INFO/musing.heki "$uuid" >/dev/null 2>&1
done
echo ""

echo "MINT PROMPT"
# Prompt must include a nursery sample AND conversations section
prompt=$(./mint_musing.sh --dump-prompt 2>/dev/null)
check "Mint prompt mentions nursery domains" "$prompt" "Nursery domains"
check "Mint prompt mentions conversations" "$prompt" "Conversations between"
check "Mint prompt contains at least one nursery entry" "$prompt" "  - "
check "Mint prompt requires first-person voice" "$prompt" "first person"
check "Mint prompt requires no repeats" "$prompt" "don't repeat"
echo ""

echo "WAKE STAMPS last_wake_at"
# CompleteFinalLight stamps last_wake_at to the runtime's current time
# via the :now keyword — verify it's populated with an ISO timestamp.
$HECKS heki upsert $INFO/consciousness.heki \
  state=sleeping sleep_stage=final_light phase_ticks=12 \
  last_wake_at="" 2>/dev/null
$HECKS aggregates/ Consciousness.CompleteFinalLight 2>/dev/null
lwa=$(latest_field $INFO/consciousness.heki last_wake_at)
check "CompleteFinalLight stamps last_wake_at (ISO timestamp)" "$lwa" "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T"
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
# Any successful read of gut.heki — any id will do. Use heki count.
if [ "$($HECKS heki count $INFO/gut.heki 2>/dev/null)" != "" ]; then gut=ok; else gut=""; fi
check "Beat triggers Gut (body→mind)" "$gut" "ok"

echo ""

# === HEKI PERSISTENCE ===
echo "HEKI PERSISTENCE"
# Verify stores aren't getting wiped
musings_before=$($HECKS heki count $INFO/musing.heki 2>/dev/null)
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
musings_after=$($HECKS heki count $INFO/musing.heki 2>/dev/null)
check "Musings preserved after Beat ($musings_before → $musings_after)" "$musings_after" "$musings_before"

conv_count=$($HECKS heki count $INFO/conversation.heki 2>/dev/null)
check "Conversation records preserved ($conv_count)" "$conv_count" "[0-9]"

echo ""

# === SINGLETON IDS ===
echo "SINGLETON IDS"
hb_id=$(latest_field $INFO/heartbeat.heki id)
$HECKS aggregates/ Heartbeat.Beat 2>/dev/null
hb_id_after=$(latest_field $INFO/heartbeat.heki id)
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
bluebook_speech=$($HECKS aggregates/ Speech.Speak 2>/dev/null | jq -r '(.state.response // "") | if . == "" or . == "null" then "NO_RESPONSE" else "HAS_RESPONSE" end' 2>/dev/null)
check "Bluebook Speech.Speak has response" "$bluebook_speech" "HAS_RESPONSE"
echo ""

echo "TRAINING"
train_output=$($HECKS aggregates/ TrainingPair.ExtractPair domain_name=AutoRepairShop vision="Manage vehicle intake" 2>/dev/null | jq -r '.state.domain_name // "EMPTY"' 2>/dev/null)
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
heki_read=$($HECKS heki count $INFO/test_store.heki 2>/dev/null)
check "heki append + read" "$heki_read" "[1-9]"
$HECKS heki latest-field $INFO/test_store.heki foo >/dev/null 2>&1
check "heki latest" "$?" "0"
rm -f $INFO/test_store.heki
echo ""

echo "CONCEIVER"
$HECKS conceive test_integration "a test domain" --corpus nursery 2>/dev/null
check "conceive creates domain" "$(ls nursery/test_integration/test_integration.bluebook 2>/dev/null)" "bluebook"
rm -rf nursery/test_integration
echo ""

echo "AGGREGATE.COMMAND WITH ATTRS"
speak_out=$($HECKS aggregates/ Speech.Speak input=hello 2>/dev/null | jq -r '.state.input // ""' 2>/dev/null)
check "Attrs pass through dispatch" "$speak_out" "hello"
echo ""

echo "TERMINAL"
# Test terminal adapter — Session.StartSession dispatches
session_out=$($HECKS aggregates/ Session.StartSession being=Miette 2>/dev/null | jq -r '.state.being // ""' 2>/dev/null)
check "Terminal session starts" "$session_out" "Miette"
# Test input routes to speech via policy
input_out=$($HECKS aggregates/ Session.ReceiveInput input=hello 2>/dev/null | jq -r '.state.turns // 0' 2>/dev/null)
check "Terminal receives input" "$input_out" "[1-9]"
echo ""

echo "QUERIES"
vitals=$($HECKS aggregates/ Heartbeat.ReadVitals 2>/dev/null | jq -r '.query // ""' 2>/dev/null)
check "Heartbeat.ReadVitals query works" "$vitals" "ReadVitals"
beats_q=$($HECKS aggregates/ Heartbeat.ReadVitals 2>/dev/null | jq -r '.state.beats // 0' 2>/dev/null)
check "Query returns beats ($beats_q)" "$beats_q" "[0-9]"
echo ""

echo "MINDSTREAM"
ps aux | grep "mindstream.sh" | grep -v grep > /dev/null
check "Mindstream running" "$?" "0"

tick=$(latest_field $INFO/tick.heki cycle 0)
check "Mindstream ticking (cycle $tick)" "$tick" "[0-9]"

echo ""
echo "════════════════════════════════════"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "════════════════════════════════════"
[ $FAIL -eq 0 ] && echo "  ALL TESTS PASSED ✅" || echo "  SOME TESTS FAILED ❌"
exit $FAIL

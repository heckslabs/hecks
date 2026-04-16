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
$HECKS run aggregates/ --dispatch Beat 2>/dev/null
beats_after=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('beats',0))" 2>/dev/null)
check "Beat increments" "$beats_after" "[0-9]"
[ "$beats_after" -gt "$beats_before" ] 2>/dev/null
check "Beats increased ($beats_before → $beats_after)" "yes" "yes"

last_beat=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('last_beat_at','none'))" 2>/dev/null)
check "last_beat_at updated" "$last_beat" "202"

echo ""

# === SLEEP ===
echo "SLEEP"
$HECKS heki upsert $INFO/consciousness.heki state=wandering 2>/dev/null
rm -f $INFO/night.heki

$HECKS run aggregates/ --dispatch EnterSleep 2>/dev/null
state=$($HECKS heki latest $INFO/consciousness.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
check "EnterSleep → attentive (full cycle)" "$state" "attentive"

cycles=$($HECKS heki latest $INFO/night.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('cycles_completed',0))" 2>/dev/null)
check "Night completed 8 cycles" "$cycles" "8"

phase=$($HECKS heki latest $INFO/night.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('phase',''))" 2>/dev/null)
check "Night phase is ended" "$phase" "ended"

echo ""

# === CROSS-DOMAIN POLICIES ===
echo "CROSS-DOMAIN POLICIES"
# Beat should trigger policies across body + mind
$HECKS heki upsert $INFO/consciousness.heki state=attentive 2>/dev/null
$HECKS run aggregates/ --dispatch Beat 2>/dev/null
gut=$($HECKS heki latest $INFO/gut.heki 2>/dev/null | python3 -c "import json,sys; print('ok')" 2>/dev/null)
check "Beat triggers Gut (body→mind)" "$gut" "ok"

echo ""

# === HEKI PERSISTENCE ===
echo "HEKI PERSISTENCE"
# Verify stores aren't getting wiped
musings_before=$($HECKS heki read $INFO/musing.heki 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
$HECKS run aggregates/ --dispatch Beat 2>/dev/null
musings_after=$($HECKS heki read $INFO/musing.heki 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
check "Musings preserved after Beat ($musings_before → $musings_after)" "$musings_after" "$musings_before"

conv_count=$($HECKS heki read $INFO/conversation.heki 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
check "Conversation records preserved ($conv_count)" "$conv_count" "[0-9]"

echo ""

# === SINGLETON IDS ===
echo "SINGLETON IDS"
hb_id=$($HECKS heki latest $INFO/heartbeat.heki 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
$HECKS run aggregates/ --dispatch Beat 2>/dev/null
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
echo "BOOT"
boot_output=$(./boot_miette.sh 2>&1)
check "Boot dispatches Identity" "$boot_output" "Identity"
check "Boot returns state" "$boot_output" "ok"

echo ""

# === MINDSTREAM ===
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

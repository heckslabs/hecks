# wake_chain_spec.rb — Phase 0c cross-aggregate chains 3, 4, 5.
#
# Three chains that ride wake-side events from Consciousness into the
# Heartbeat / WakeMood / Mood aggregates. Today these are silently
# assumed by the wake ritual ; this spec makes them explicit.
#
# Chains under test :
#
#   3. Consciousness.AdvanceRemToDeep
#        → emits DeepEntered
#        → Heartbeat.RecoverFatigue ?
#      GAP : no policy exists today. The plan's chain inventory lists
#      this but no `RecoverFatigueOnDeep` policy is declared anywhere.
#      DeepEntered is consumed only by EndLucidityOnDeep (lucid_dream).
#      The spec asserts the gap with `pending` so it turns green when
#      the policy lands ; the inbox-ready reason names the missing
#      policy by the conventional name.
#
#   4. Consciousness.WakeUp
#        → emits WokenUp
#        → policy `RecoverHeartbeatOnWake` (heartbeat.bluebook)
#        → Heartbeat.RecoverFatigue
#        → heartbeat.fatigue=0.0, fatigue_state="alert", pulses_since_sleep=0
#      Plus : `OpenFatigueGateOnWake` flips heartbeat.sleep_gate to "open".
#
#   5. Consciousness.WakeUp
#        → emits WokenUp + ClassifyFullWake/ClassifyPartialWake (cycle gate)
#        → emits WokeFullSleep | WokePartialSleep
#        → policy `RefreshOnFullSleep` / `GroggyOnPartialSleep` (mood.bluebook)
#        → Mood.RefreshMood / Mood.SetGroggy
#      The audit's "WokenUp → WakeMood.SetWakeMood" line was imprecise :
#      production routes through Mood, not WakeMood. WakeMood has NO
#      incoming policy today (wake_mood.bluebook header : "No policies
#      target this aggregate today"). The spec asserts BOTH : the
#      production chain (WokenUp → Mood) lands ; the nominal
#      WakeMood chain is `pending` so the planned future policy lights up.
#
# Audit cross-reference :
#   `dream-study/test-gate/test-audit.md` § 0c, chains 3 / 4 / 5.
#
# Run :
#   cd dream-study/test-gate/cross_aggregate
#   rspec wake_chain_spec.rb

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "rspec"
require "cross_aggregate_helper"

RSpec.describe "wake chain — chains 3, 4, 5" do
  let(:helper) { CrossAggregateHelper.new }

  describe "chain 3 : DeepEntered → Heartbeat.RecoverFatigue" do
    # GAP : the plan lists this chain but no policy exists.
    # Today : `EndLucidityOnDeep` (lucid_dream.bluebook) is the ONLY
    # policy on DeepEntered ; heartbeat.bluebook carries no
    # `RecoverFatigueOnDeep`. The fatigue ladder only resets on
    # WokenUp (chain 4) — recovering mid-cycle would defeat the
    # accumulator's purpose. The plan likely conflated this with
    # WokenUp → RecoverFatigue. Filed as inbox at gaps.md.
    it "fires RecoverFatigue on entering deep sleep (NOT WIRED today — gap)" do
      pending(
        "no policy `RecoverFatigueOnDeep` exists. DeepEntered is " \
        "consumed only by EndLucidityOnDeep. Recovering mid-cycle " \
        "would defeat the fatigue accumulator. See gaps.md."
      )
      helper.seed_consciousness(
        state: "sleeping", sleep_stage: "rem",
        sleep_cycle: 1, sleep_total: 8,
        dream_pulses: 5, dream_pulses_needed: 5,
        is_lucid: "no",
      )
      # Accumulate some fatigue to make the recovery observable.
      helper.step("AccumulateFatigue")
      pre = helper.heartbeat_attr(:fatigue)
      expect(pre.to_f).to be > 0

      helper.step("AdvanceRemToDeep")

      # Post-policy assertion (currently fails ; will pass when policy lands).
      # i201 closure : RecoverFatigue → "rested" (was "alert").
      expect(helper.heartbeat_attr(:fatigue_state)).to eq("rested")
      expect(helper.heartbeat_attr(:fatigue).to_f).to eq(0.0)
      expect(helper.heartbeat_attr(:pulses_since_sleep).to_i).to eq(0)
    end

    it "today : DeepEntered does NOT touch heartbeat.fatigue (regression-locks current behaviour)" do
      # Lock the today-behavior so the gap-filling PR has to flip BOTH
      # this assertion and the pending one above. Prevents accidental
      # mid-cycle fatigue reset before the policy decision is made.
      helper.seed_consciousness(
        state: "sleeping", sleep_stage: "rem",
        sleep_cycle: 1, sleep_total: 8,
        dream_pulses: 5, dream_pulses_needed: 5,
        is_lucid: "no",
      )
      # Heartbeat starts with sleep_gate=closed (CloseFatigueGateOnSleep
      # would have fired on SleepEntered — we're skipping that hop here).
      # The spec asserts only that DeepEntered-driven recovery does NOT
      # secretly fire today.
      helper.step("AdvanceRemToDeep")
      expect(helper.emitted?("DeepEntered")).to be(true)
      expect(helper.emitted?("FatigueRecovered")).to be(false)
    end
  end

  describe "chain 4 : WokenUp → Heartbeat.RecoverFatigue + OpenFatigueGate" do
    it "RecoverHeartbeatOnWake fires RecoverFatigue and clears the fatigue ladder" do
      # Wind the body into a sleep + accumulate some fatigue so recovery
      # is observable. Use the real EnterSleep / WakeUp pair so the
      # full policy chain fires.
      helper.step("EnterSleep", sleep_at: "2026-05-01T22:00:00Z")
      # Sleep gate closed by CloseFatigueGateOnSleep ; AccumulateFatigue
      # is now refused. Re-open just for setup, accumulate, re-close.
      helper.step("OpenFatigueGate")
      helper.step("AccumulateFatigue")
      helper.step("CloseFatigueGate")
      expect(helper.heartbeat_attr(:fatigue).to_f).to be > 0

      helper.step("WakeUp", wake_at: "2026-05-02T06:00:00Z")

      expect(helper.emitted?("WokenUp")).to be(true)
      # Fatigue cleared by RecoverFatigue.
      # i201 closure : lands at "rested" (was "alert") ; BecomeAlert
      # walks rested → alert as pulses cross 10.
      expect(helper.heartbeat_attr(:fatigue_state)).to eq("rested")
      expect(helper.heartbeat_attr(:fatigue).to_f).to eq(0.0)
      expect(helper.heartbeat_attr(:pulses_since_sleep).to_i).to eq(0)
      expect(helper.emitted?("FatigueRecovered")).to be(true)
    end

    it "OpenFatigueGateOnWake flips sleep_gate back to open" do
      helper.step("EnterSleep", sleep_at: "2026-05-01T22:00:00Z")
      expect(helper.heartbeat_attr(:sleep_gate)).to eq("closed")

      helper.step("WakeUp", wake_at: "2026-05-02T06:00:00Z")

      expect(helper.heartbeat_attr(:sleep_gate)).to eq("open")
      expect(helper.emitted?("FatigueGateOpened")).to be(true)
    end
  end

  describe "chain 5 : WokenUp → mood update" do
    # Production reality : WokenUp fans out to ClassifyFullWake +
    # ClassifyPartialWake (only the matching given fires) ; the
    # resulting WokeFullSleep | WokePartialSleep event triggers
    # Mood.RefreshMood | Mood.SetGroggy.
    #
    # The audit's "WokenUp → WakeMood.SetWakeMood" line names the
    # WakeMood aggregate, which has NO incoming policy today.

    it "WokenUp after a full sleep cascades to Mood.RefreshMood" do
      # Full sleep means sleep_cycle >= sleep_total at wake time. Drive
      # EnterSleep then artificially seed sleep_cycle=8 so ClassifyFullWake
      # fires.
      helper.step("EnterSleep", sleep_at: "2026-05-01T22:00:00Z")
      helper.seed_consciousness(
        state: "sleeping", sleep_stage: "final_light",
        sleep_cycle: 8, sleep_total: 8,
      )

      helper.step("WakeUp", wake_at: "2026-05-02T06:00:00Z")

      expect(helper.emitted?("WokenUp")).to be(true)
      expect(helper.emitted?("WokeFullSleep")).to be(true)
      expect(helper.mood_attr(:current_state)).to eq("refreshed")
      expect(helper.emitted?("MoodRefreshed")).to be(true)
    end

    it "WokenUp after a partial sleep cascades to Mood.SetGroggy" do
      # Default EnterSleep leaves sleep_cycle=1 ; an immediate WakeUp
      # therefore takes the partial branch.
      helper.step("EnterSleep", sleep_at: "2026-05-01T22:00:00Z")
      helper.step("WakeUp", wake_at: "2026-05-01T22:30:00Z")

      expect(helper.emitted?("WokePartialSleep")).to be(true)
      expect(helper.mood_attr(:current_state)).to eq("groggy")
      expect(helper.emitted?("MoodGroggy")).to be(true)
    end

    it "WokenUp does NOT touch the WakeMood aggregate today (planned policy gap)" do
      pending(
        "WakeMood has no incoming policy. wake_mood.bluebook explicitly " \
        "notes : 'No policies target this aggregate today.' The plan's " \
        "chain inventory lists WokenUp → WakeMood.SetWakeMood as a " \
        "future hop. See gaps.md."
      )
      helper.step("EnterSleep", sleep_at: "2026-05-01T22:00:00Z")
      helper.step("WakeUp", wake_at: "2026-05-01T22:30:00Z")

      # Post-policy : WakeMood.mood populated by SetWakeMood.
      expect(helper.wake_mood_attr(:mood)).not_to be_nil
      expect(helper.wake_mood_attr(:mood)).not_to eq("")
      expect(helper.emitted?("WakeMoodSet")).to be(true)
    end
  end
end

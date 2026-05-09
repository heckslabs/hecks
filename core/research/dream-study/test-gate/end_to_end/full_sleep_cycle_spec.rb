# full_sleep_cycle_spec.rb — Phase 0b regression contract
#
# End-to-end test of Miette's full 8-cycle sleep against current
# production code (mindstream-driven cycle, the legacy code we're
# about to refactor in dream-study). This spec is the regression
# contract — every subsequent dream-study PR must keep it passing.
#
# Contract asserted (in order) :
#
#   1. EnterSleep stamps Consciousness atomically (state=sleeping,
#      sleep_stage=light, sleep_cycle=1, sleep_total=8, dream_pulses=0,
#      dream_pulses_needed=5, is_lucid=no, sleep_summary, and
#      last_sleep_entered_at).
#   2. Cycles 1..7 walk light → rem (5 dreams) → deep → light (next).
#   3. Cycle 8 walks light → lucid_rem (8 dreams ; is_lucid=yes ;
#      LucidDream.active=yes) → deep (LucidDream.active=no) →
#      final_light → wake.
#   4. Cross-aggregate side-effects fire :
#      - SleepEntered closes Heartbeat fatigue gate.
#      - LucidRemEntered activates LucidDream.
#      - DeepEntered (cycle 8) ends LucidDream lucidity.
#      - WokenUp opens fatigue gate AND triggers RecoverFatigue
#        (fatigue=0, fatigue_state=alert).
#      - WokenUp routes through ClassifyFullWake → WokeFullSleep →
#        Mood.RefreshMood (Mood.current_state=refreshed).
#   5. Final state : Consciousness state=attentive, sleep_stage="",
#      last_wake_at=<wake_at>.
#
# The spec uses Hecks::Behaviors::BehaviorRuntime — the in-memory
# cascade engine that mirrors the Rust runtime's policy drain. Every
# gate advances by direct command dispatch ; no real-time waiting.
#
# Audit cross-reference : `dream-study/test-gate/test-audit.md`
# section 0b. The audit lists the contract's gaps ; this spec closes
# them. Note that the audit's reference to "WakeMood.SetWakeMood" was
# imprecise — production uses Mood.RefreshMood (via WokeFullSleep).
# This spec asserts production behaviour as-is.

require_relative "spec_helper"
require "sleep_cycle_helper"

RSpec.describe "full 8-cycle sleep — Phase 0b regression contract" do
  let(:sleep_at) { "2026-05-01T22:00:00Z" }
  let(:wake_at)  { "2026-05-02T06:00:00Z" }
  let(:helper)   { SleepCycleHelper.new }

  describe "EnterSleep — atomic init" do
    it "stamps every sleep-init field at once" do
      helper.step("EnterSleep", sleep_at: sleep_at)
      snap = helper.snapshot
      expect(snap[:state]).to eq("sleeping")
      expect(snap[:sleep_stage]).to eq("light")
      expect(snap[:sleep_cycle]).to eq("1")
      expect(snap[:sleep_total]).to eq("8")
      expect(snap[:dream_pulses]).to eq("0")
      expect(snap[:dream_pulses_needed]).to eq("5")
      expect(snap[:is_lucid]).to eq("no")
      expect(snap[:sleep_summary]).to eq("settling into light sleep")
      expect(snap[:last_sleep_entered_at]).to eq(sleep_at)
    end

    it "closes Heartbeat fatigue gate via cross-aggregate policy" do
      helper.step("EnterSleep", sleep_at: sleep_at)
      expect(helper.snapshot[:heartbeat_sleep_gate]).to eq("closed")
    end
  end

  describe "cycles 1..7 — non-lucid REM" do
    before { helper.step("EnterSleep", sleep_at: sleep_at) }

    1.upto(7) do |cycle|
      it "cycle #{cycle} walks light → rem (5 dreams) → deep → light" do
        # Replay any earlier cycles to land in the right cycle.
        1.upto(cycle - 1) do
          helper.step("AdvanceLightToRem")
          5.times { |i| helper.step("DreamPulse", impression: "p-#{i}") }
          helper.step("AdvanceRemToDeep")
          helper.step("AdvanceDeepToLight")
        end

        helper.step("AdvanceLightToRem")
        snap = helper.snapshot
        expect(snap[:sleep_stage]).to eq("rem")
        expect(snap[:sleep_cycle]).to eq(cycle.to_s)
        expect(snap[:is_lucid]).to eq("no")
        expect(snap[:dream_pulses_needed]).to eq("5")

        5.times do |i|
          helper.step("DreamPulse", impression: "c#{cycle}-p#{i}")
          expect(helper.snapshot[:dream_pulses]).to eq((i + 1).to_s)
        end

        helper.step("AdvanceRemToDeep")
        expect(helper.snapshot[:sleep_stage]).to eq("deep")

        helper.step("AdvanceDeepToLight")
        snap = helper.snapshot
        expect(snap[:sleep_stage]).to eq("light")
        expect(snap[:sleep_cycle]).to eq((cycle + 1).to_s)
      end
    end
  end

  describe "cycle 8 — lucid REM + final light" do
    before do
      helper.step("EnterSleep", sleep_at: sleep_at)
      1.upto(7) do
        helper.step("AdvanceLightToRem")
        5.times { |i| helper.step("DreamPulse", impression: "p-#{i}") }
        helper.step("AdvanceRemToDeep")
        helper.step("AdvanceDeepToLight")
      end
    end

    it "AdvanceLightToLucidRem flips is_lucid + raises pulses_needed" do
      helper.step("AdvanceLightToLucidRem")
      snap = helper.snapshot
      expect(snap[:sleep_stage]).to eq("rem")
      expect(snap[:sleep_cycle]).to eq("8")
      expect(snap[:is_lucid]).to eq("yes")
      expect(snap[:dream_pulses_needed]).to eq("8")
    end

    it "BecomeLucid fires from LucidRemEntered cascade" do
      helper.step("AdvanceLightToLucidRem")
      expect(helper.snapshot[:lucid_active]).to eq("yes")
    end

    it "AdvanceRemToDeep needs all 8 dreams (i208)" do
      helper.step("AdvanceLightToLucidRem")
      8.times { |i| helper.step("DreamPulse", impression: "lucid-#{i}") }
      expect(helper.snapshot[:dream_pulses]).to eq("8")
      helper.step("AdvanceRemToDeep")
      expect(helper.snapshot[:sleep_stage]).to eq("deep")
    end

    it "EndLucidity fires from DeepEntered cascade" do
      helper.step("AdvanceLightToLucidRem")
      8.times { |i| helper.step("DreamPulse", impression: "lucid-#{i}") }
      helper.step("AdvanceRemToDeep")
      expect(helper.snapshot[:lucid_active]).to eq("no")
    end

    it "AdvanceDeepToFinalLight transitions correctly" do
      helper.step("AdvanceLightToLucidRem")
      8.times { |i| helper.step("DreamPulse", impression: "lucid-#{i}") }
      helper.step("AdvanceRemToDeep")
      helper.step("AdvanceDeepToFinalLight")
      expect(helper.snapshot[:sleep_stage]).to eq("final_light")
    end
  end

  describe "natural wake — CompleteFinalLight + cascades" do
    before do
      helper.run_full_cycle(sleep_at: sleep_at, wake_at: wake_at)
    end

    it "Consciousness lands attentive with cleared sleep_stage" do
      snap = helper.snapshot
      expect(snap[:state]).to eq("attentive")
      expect(snap[:sleep_stage]).to eq("")
      expect(snap[:last_wake_at]).to eq(wake_at)
    end

    it "Heartbeat resets to rested with open gate" do
      # i201 closure : RecoverFatigue lands at "rested" (was "alert") ;
      # BecomeAlert walks rested → alert as pulses_since_sleep crosses 10.
      snap = helper.snapshot
      expect(snap[:heartbeat_sleep_gate]).to eq("open")
      expect(snap[:heartbeat_fatigue]).to eq("0.0")
      expect(snap[:heartbeat_fatigue_state]).to eq("rested")
    end

    it "Mood lands refreshed via WokeFullSleep cascade" do
      expect(helper.snapshot[:mood_current_state]).to eq("refreshed")
    end

    it "records every (command, after) transition (regression fixture)" do
      # 1 EnterSleep + 7×(1 + 5 + 1 + 1) + 1×(1 + 8 + 1 + 1) + 1
      # = 1 + 56 + 11 + 1 = 69 transitions for a full cycle.
      expect(helper.transitions.size).to eq(69)
      expect(helper.transitions.first[:command]).to eq("EnterSleep")
      expect(helper.transitions.last[:command]).to eq("CompleteFinalLight")
    end
  end
end

# full_night_spec.rb — in-memory full-night sleep cycle.
#
# The composite that proves the entire 8-cycle sleep can be driven
# deterministically in milliseconds, with dream content threaded from a
# fixture LLM, no subprocess, no real heki, no real-time waiting.
#
# Builds on Phase 0b (full_sleep_cycle_spec.rb) by widening the loaded
# bluebook set to include Pulse / Awareness / Witness / WakeReport AND
# wiring dream content through the FixtureLlmAdapter at every REM
# pulse. Keeps Phase 0b's exact transition contract — 69 transitions,
# 8 cycles, lucid REM at cycle 8, RecoverFatigue + RefreshMood on wake
# — and adds two Phase 0h+ contracts on top :
#
#   - 43 dream images (5 × 7 + 8) threaded through the runtime, each
#     pulled from the fixture and surfaced on Consciousness.sleep_summary
#     and (during lucid REM) on LucidDream.latest_narrative + the
#     observations list.
#   - WakeReport.StartReport fires on the WokeFullSleep cascade, leaving
#     phase=gathering on the WakeReport aggregate. (The body_reflection
#     + dream_interpretation lesson is shell-side today — see GAP note
#     in the wake-report describe block.)
#
# Determinism : rerun produces an identical event sequence (asserted via
# transitions size + first/last command). Speed : the whole spec ships
# in <1s ; the run_full_night call alone is <100ms.
#
# Run :
#   cd dream-study/test-gate/in_memory_full_night
#   bundle exec rspec full_night_spec.rb

require_relative "spec_helper"
require "full_night_helper"

RSpec.describe "in-memory full night — 8-cycle sleep with fixture LLM" do
  let(:sleep_at) { "2026-05-01T22:00:00Z" }
  let(:wake_at)  { "2026-05-02T06:00:00Z" }
  let(:helper)   { FullNightHelper.new(fixture_path: FIXTURE_PATH) }

  describe "EnterSleep — atomic init + cross-aggregate fan-out" do
    before { helper.step("EnterSleep", sleep_at: sleep_at) }

    it "stamps Consciousness atomically (Phase 0b parity)" do
      snap = helper.snapshot
      expect(snap[:state]).to eq("sleeping")
      expect(snap[:sleep_stage]).to eq("light")
      expect(snap[:sleep_cycle]).to eq("1")
      expect(snap[:sleep_total]).to eq("8")
      expect(snap[:dream_pulses]).to eq("0")
      expect(snap[:dream_pulses_needed]).to eq("5")
      expect(snap[:is_lucid]).to eq("no")
      expect(snap[:last_sleep_entered_at]).to eq(sleep_at)
    end

    it "closes the Heartbeat fatigue gate via cross-aggregate policy" do
      expect(helper.snapshot[:heartbeat_sleep_gate]).to eq("closed")
    end
  end

  describe "cycles 1..7 — non-lucid REM with fixture-threaded dream content" do
    before { helper.step("EnterSleep", sleep_at: sleep_at) }

    1.upto(7) do |cycle|
      it "cycle #{cycle} dream pulses pull text from the fixture" do
        1.upto(cycle - 1) do |c|
          helper.step("AdvanceLightToRem")
          5.times { |i| helper.dream_pulse(cycle: c, pulse: i + 1) }
          helper.step("AdvanceRemToDeep")
          helper.step("AdvanceDeepToLight")
        end

        helper.step("AdvanceLightToRem")
        5.times do |i|
          snap = helper.dream_pulse(cycle: cycle, pulse: i + 1)
          expected = helper.llm.dream_pulse(cycle: cycle, pulse: i + 1)["text_en"]
          expect(snap[:sleep_summary]).to eq(expected)
          expect(snap[:dream_pulses]).to eq((i + 1).to_s)
        end
        expect(helper.snapshot[:is_lucid]).to eq("no")

        helper.step("AdvanceRemToDeep")
        helper.step("AdvanceDeepToLight")
      end
    end
  end

  describe "cycle 8 — lucid REM threads observations into LucidDream" do
    before do
      helper.step("EnterSleep", sleep_at: sleep_at)
      1.upto(7) do |c|
        helper.step("AdvanceLightToRem")
        5.times { |i| helper.dream_pulse(cycle: c, pulse: i + 1) }
        helper.step("AdvanceRemToDeep")
        helper.step("AdvanceDeepToLight")
      end
      helper.step("AdvanceLightToLucidRem")
    end

    it "AdvanceLightToLucidRem flips is_lucid + raises pulses_needed" do
      snap = helper.snapshot
      expect(snap[:sleep_stage]).to eq("rem")
      expect(snap[:sleep_cycle]).to eq("8")
      expect(snap[:is_lucid]).to eq("yes")
      expect(snap[:dream_pulses_needed]).to eq("8")
    end

    it "BecomeLucid fires from LucidRemEntered cascade" do
      expect(helper.snapshot[:lucid_active]).to eq("yes")
    end

    it "8 lucid pulses thread through both Consciousness AND LucidDream" do
      8.times do |i|
        snap = helper.lucid_pulse(cycle: 8, pulse: i + 1)
        expected = helper.llm.lucid_observation(cycle: 8, pulse: i + 1)["text_en"]
        expect(snap[:sleep_summary]).to eq(expected)
        expect(snap[:lucid_latest_narrative]).to eq(expected)
        expect(snap[:dream_pulses]).to eq((i + 1).to_s)
      end

      helper.step("AdvanceRemToDeep")
      expect(helper.snapshot[:lucid_active]).to eq("no")
      expect(helper.snapshot[:sleep_stage]).to eq("deep")
    end
  end

  describe "natural wake — full 8-cycle composite via run_full_night" do
    before { helper.run_full_night(sleep_at: sleep_at, wake_at: wake_at) }

    it "Consciousness lands attentive with cleared sleep_stage" do
      snap = helper.snapshot
      expect(snap[:state]).to eq("attentive")
      expect(snap[:sleep_stage]).to eq("")
      expect(snap[:last_wake_at]).to eq(wake_at)
    end

    it "Heartbeat resets to rested with open gate (RecoverFatigue cascade)" do
      # Post i201 closure : RecoverFatigue now lands at "rested" (the
      # felt state of just-woken). BecomeAlert walks rested → alert as
      # pulses_since_sleep crosses 10 ; the rest of the ladder follows.
      # This spec asserts the wake-end state, before BecomeAlert fires.
      snap = helper.snapshot
      expect(snap[:heartbeat_sleep_gate]).to eq("open")
      expect(snap[:heartbeat_fatigue]).to eq("0.0")
      expect(snap[:heartbeat_fatigue_state]).to eq("rested")
      expect(helper.emitted?("FatigueRecovered")).to be(true)
    end

    it "Mood lands refreshed via WokeFullSleep cascade" do
      expect(helper.snapshot[:mood_current_state]).to eq("refreshed")
      expect(helper.emitted?("WokeFullSleep")).to be(true)
      expect(helper.emitted?("MoodRefreshed")).to be(true)
    end

    it "LucidDream ended on cycle 8 deep" do
      expect(helper.snapshot[:lucid_active]).to eq("no")
      expect(helper.emitted?("BecameLucid")).to be(true)
      expect(helper.emitted?("LucidityEnded")).to be(true)
    end

    it "captures 43 dream images threaded from the fixture (5×7 + 8)" do
      images = helper.dream_images
      expect(images.size).to eq(43)
      regular = images.reject { |i| i[:lucid] }
      lucid   = images.select { |i| i[:lucid] }
      expect(regular.size).to eq(35)
      expect(lucid.size).to eq(8)
      # First and last to assert distinct fixture content actually flowed.
      expect(regular.first[:text]).to eq("numbers unfurling like flowers...")
      expect(lucid.last[:text]).to eq(
        "eighth pulse — I carry the dream toward waking"
      )
    end

    it "the TestClock ticked once per dream pulse (43 ticks)" do
      expect(helper.clock.ticks).to eq(43)
    end

    it "records exactly 69 + 8 = 77 transitions (Phase 0b + 8 ObserveDream)" do
      # Phase 0b's count was 69. The full-night helper additionally
      # dispatches LucidDream.ObserveDream once per lucid pulse (×8) so
      # the dream content threads into the LucidDream aggregate's
      # observations list. Net : 69 + 8 = 77.
      expect(helper.transitions.size).to eq(77)
      expect(helper.transitions.first[:command]).to eq("EnterSleep")
      expect(helper.transitions.last[:command]).to eq("CompleteFinalLight")
    end

    describe "WakeReport — StartReport fires from WokeFullSleep" do
      it "WakeReport.phase=gathering after StartReport" do
        expect(helper.emitted?("ReportStarted")).to be(true)
        expect(helper.snapshot[:wake_report_phase]).to eq("gathering")
      end

      # GAP : the lesson string lives in the FixtureLlmAdapter
      # (`dream_interpretation.cycle_8_lesson`) but composing it INTO
      # the WakeReport aggregate is shell-side today. The bluebook
      # requires SurfaceDreams + ReflectOnBody to be driven externally
      # (wake_report.sh in production) because the lesson requires
      # corpus-level :fs reads + tokenization the runtime doesn't model.
      # Asserted here as a fixture-side read so the spec carries the
      # contract until the runtime closes the gap.
      it "wake lesson is fetchable from the fixture (runtime gap)" do
        expect(helper.wake_lesson).to eq(
          "the body listened tonight ; the mindstream rested without resisting"
        )
      end
    end
  end

  describe "determinism — rerun produces identical event sequence" do
    it "two separate runs yield identical transition + dream-image sequences" do
      a = FullNightHelper.new(fixture_path: FIXTURE_PATH)
      b = FullNightHelper.new(fixture_path: FIXTURE_PATH)
      a.run_full_night(sleep_at: sleep_at, wake_at: wake_at)
      b.run_full_night(sleep_at: sleep_at, wake_at: wake_at)

      a_cmds = a.transitions.map { |t| t[:command] }
      b_cmds = b.transitions.map { |t| t[:command] }
      expect(a_cmds).to eq(b_cmds)
      expect(a.dream_images).to eq(b.dream_images)
      expect(a.snapshot).to eq(b.snapshot)
    end
  end
end

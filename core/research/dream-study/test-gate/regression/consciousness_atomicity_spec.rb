# consciousness_atomicity_spec.rb
#
# [antibody-exempt: dream-study Phase 0f regression — covers named
#  bugs i196 + i197 ; retires once Body PR migrates to .behaviors]
#
# Regression coverage for i196 + i197 — the partial-write bugs in
# Consciousness.EnterSleep and Consciousness.WakeUp. Both commands
# must atomically stamp their timestamp + clear their cleared fields
# alongside the lifecycle transition. Pre-fix : a mid-dispatch death
# could leave state=sleeping with last_sleep_entered_at=null (i196)
# or state=waking without last_wake_at populated (i197).
#
# Specs : seed an EnterDaydream→EnterSleep / WakeUp pair and verify
# the heki row carries every stamped field in one write.

require_relative "spec_helper"

RSpec.describe "Consciousness atomicity (i196, i197)" do
  let(:bluebook) { File.join(MIETTE_DIR, "body/sleep/consciousness.bluebook") }

  context "i196 — EnterSleep stamps last_sleep_entered_at + sleep_stage + cycle counters atomically" do
    it "writes all initialisation fields in a single dispatch" do
      h = setup_harness("i196_enter_sleep")
      h.copy_bluebook(bluebook)

      result = h.dispatch(
        "Consciousness.EnterSleep",
        name:     "consciousness",
        sleep_at: "2026-05-01T03:00:00Z"
      )
      expect(result).to be_ok, "EnterSleep dispatch failed: #{result.error_message}"

      row = h.heki_latest("consciousness/consciousness.heki")
      aggregate_failures "EnterSleep partial-write guard" do
        expect(row["state"]).to                 eq("sleeping")
        expect(row["sleep_stage"]).to           eq("light")
        expect(row["sleep_cycle"]).to           eq(1)
        expect(row["sleep_total"]).to           eq(8)
        expect(row["phase_ticks"]).to           eq(0)
        expect(row["dream_pulses"]).to          eq(0)
        expect(row["dream_pulses_needed"]).to   eq(5)
        expect(row["is_lucid"]).to              eq("no")
        # The i196 lesson : last_sleep_entered_at MUST be stamped in
        # the same dispatch — never null when state==sleeping.
        expect(row["last_sleep_entered_at"]).to eq("2026-05-01T03:00:00Z")
      end
    end
  end

  context "i197 — WakeUp stamps last_wake_at + clears sleep_stage atomically" do
    it "stamps last_wake_at to the passed wake_at value, never null" do
      h = setup_harness("i197_wake_up")
      h.copy_bluebook(bluebook)

      enter = h.dispatch(
        "Consciousness.EnterSleep",
        name:     "consciousness",
        sleep_at: "2026-05-01T03:00:00Z"
      )
      expect(enter).to be_ok, "EnterSleep setup failed: #{enter.error_message}"

      result = h.dispatch(
        "Consciousness.WakeUp",
        name:    "consciousness",
        wake_at: "2026-05-01T07:30:00Z"
      )
      expect(result).to be_ok, "WakeUp dispatch failed: #{result.error_message}"

      row = h.heki_latest("consciousness/consciousness.heki")
      aggregate_failures "WakeUp partial-write guard" do
        # WakeUp transitions to "waking" ; the AttentiveOnWake policy
        # cascades to BecomeAttentive in the same dispatch chain, so
        # the row settles to "attentive". Either is acceptable — the
        # i197 contract is about the timestamp, not the transient state.
        expect(%w[waking attentive]).to include(row["state"])
        # The i197 lesson : the passed wake_at must reach the heki row
        # in the same write that flipped state. Pre-fix : last_wake_at
        # stayed empty because the command's then_set chain dropped it.
        expect(row["last_wake_at"]).to eq("2026-05-01T07:30:00Z")
        expect(row["sleep_stage"]).to  eq("")
      end
    end

    it "does not regress last_sleep_entered_at when WakeUp lands" do
      # i196 + i197 together : WakeUp must not blank the prior sleep
      # timestamp ; both stamps coexist on the same row.
      h = setup_harness("i197_preserve_sleep_stamp")
      h.copy_bluebook(bluebook)

      h.dispatch("Consciousness.EnterSleep", name: "consciousness",
                                              sleep_at: "2026-05-01T03:00:00Z")
      h.dispatch("Consciousness.WakeUp", name: "consciousness",
                                          wake_at: "2026-05-01T07:30:00Z")
      row = h.heki_latest("consciousness/consciousness.heki")
      expect(row["last_sleep_entered_at"]).to eq("2026-05-01T03:00:00Z")
      expect(row["last_wake_at"]).to          eq("2026-05-01T07:30:00Z")
    end
  end
end

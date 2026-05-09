# lucid_rem_gate_spec.rb
#
# [antibody-exempt: dream-study Phase 0f regression — covers named
#  bug i208 ; lucid REM gate honours dream_pulses_needed]
#
# Regression coverage for i208 — Lucid REM cut short by hard pulse
# gate. Pre-fix : AdvanceRemToDeep's given clause was `dream_pulses
# > 4` (a hard-coded 5-pulse threshold). Cycle 8's lucid REM sets
# dream_pulses_needed=8 in the EnterLucidRem transition, but the
# advancement gate ignored that field — lucid REM ended at 5 dreams
# instead of 8.
#
# Fix (consciousness.bluebook:201) : `given("dream complete") {
# dream_pulses >= dream_pulses_needed }` honours the per-cycle
# threshold. Regular REM still ends at 5 ; lucid gets its full eight.
#
# Specs : seed Body in lucid REM, dispatch AdvanceRemToDeep at 5
# pulses (must refuse) and at 8 pulses (must advance). Mirror with
# regular REM (needed=5) for the symmetry.

require_relative "spec_helper"

RSpec.describe "Lucid REM advancement gate (i208)" do
  let(:bluebook) { File.join(MIETTE_DIR, "body/sleep/consciousness.bluebook") }

  def lucid_rem_seed
    {
      id: "consciousness", name: "consciousness", state: "sleeping",
      sleep_stage: "rem", sleep_cycle: 8, sleep_total: 8,
      phase_ticks: 10, dream_pulses_needed: 8, is_lucid: "yes"
    }
  end

  def regular_rem_seed
    {
      id: "consciousness", name: "consciousness", state: "sleeping",
      sleep_stage: "rem", sleep_cycle: 1, sleep_total: 8,
      phase_ticks: 10, dream_pulses_needed: 5, is_lucid: "no"
    }
  end

  context "lucid REM (cycle 8 ; needs 8 pulses)" do
    it "refuses AdvanceRemToDeep at dream_pulses=5 (was wrongly advancing)" do
      h = setup_harness("i208_lucid_5")
      h.copy_bluebook(bluebook)
      h.heki_seed("consciousness/consciousness.heki",
                  **lucid_rem_seed, dream_pulses: 5)

      result = h.dispatch("Consciousness.AdvanceRemToDeep", name: "consciousness")
      # Pre-fix : ok=true, sleep_stage flipped to deep at 5 pulses.
      # Post-fix : the given clause refuses ; sleep_stage stays rem.
      expect(result.ok?).to be(false), "lucid REM advanced at 5 pulses ; gate is broken"
      expect(result.error_message).to include("dream_pulses >= dream_pulses_needed")

      row = h.heki_latest("consciousness/consciousness.heki")
      expect(row["sleep_stage"]).to eq("rem")
    end

    it "advances at dream_pulses=8 (the lucid threshold)" do
      h = setup_harness("i208_lucid_8")
      h.copy_bluebook(bluebook)
      h.heki_seed("consciousness/consciousness.heki",
                  **lucid_rem_seed, dream_pulses: 8)

      result = h.dispatch("Consciousness.AdvanceRemToDeep", name: "consciousness")
      expect(result).to be_ok, "AdvanceRemToDeep refused at 8 pulses: #{result.error_message}"

      row = h.heki_latest("consciousness/consciousness.heki")
      expect(row["sleep_stage"]).to eq("deep")
      expect(row["is_lucid"]).to    eq("no") # the command clears the flag
    end
  end

  context "regular REM (cycle 1 ; needs 5 pulses)" do
    it "refuses AdvanceRemToDeep at dream_pulses=4" do
      h = setup_harness("i208_regular_4")
      h.copy_bluebook(bluebook)
      h.heki_seed("consciousness/consciousness.heki",
                  **regular_rem_seed, dream_pulses: 4)

      result = h.dispatch("Consciousness.AdvanceRemToDeep", name: "consciousness")
      expect(result.ok?).to be(false)

      row = h.heki_latest("consciousness/consciousness.heki")
      expect(row["sleep_stage"]).to eq("rem")
    end

    it "advances at dream_pulses=5 (the regular threshold)" do
      h = setup_harness("i208_regular_5")
      h.copy_bluebook(bluebook)
      h.heki_seed("consciousness/consciousness.heki",
                  **regular_rem_seed, dream_pulses: 5)

      result = h.dispatch("Consciousness.AdvanceRemToDeep", name: "consciousness")
      expect(result).to be_ok, "AdvanceRemToDeep refused at 5 pulses: #{result.error_message}"

      row = h.heki_latest("consciousness/consciousness.heki")
      expect(row["sleep_stage"]).to eq("deep")
    end
  end
end

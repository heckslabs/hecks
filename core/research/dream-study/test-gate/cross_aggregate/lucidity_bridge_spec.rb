# lucidity_bridge_spec.rb — Phase 0c cross-aggregate chains 1, 2, 8.
#
# Three chains that bridge sleep-stage transitions / meta-awareness to
# the LucidDream aggregate. Today they're silently assumed by every
# subsequent dream-study PR ; this spec makes them explicit.
#
# Chains under test :
#
#   1. Consciousness.AdvanceLightToLucidRem
#        → emits LucidRemEntered
#        → policy `BecomeLucidOnFinalRem` (lucid_dream.bluebook)
#        → LucidDream.BecomeLucid
#        → LucidDream.active = "yes" + emits BecameLucid
#
#   2. Consciousness.AdvanceRemToDeep (final cycle, after lucid REM)
#        → emits DeepEntered
#        → policy `EndLucidityOnDeep` (lucid_dream.bluebook)
#        → LucidDream.EndLucidity
#        → LucidDream.active = "no" + emits LucidityEnded
#
#   8. Witness.ReflectOnObservation
#        → emits ReflectionOccurred
#        → policy `LucidOnReflection across "Dream"` (witness.bluebook)
#        → LucidDream.BecomeLucid
#        → LucidDream.active = "yes" + emits BecameLucid
#
# Audit cross-reference :
#   `dream-study/test-gate/test-audit.md` § 0c, chains 1 / 2 / 8.
#
# Run :
#   cd dream-study/test-gate/cross_aggregate
#   rspec lucidity_bridge_spec.rb

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "rspec"
require "cross_aggregate_helper"

RSpec.describe "lucidity bridge — chains 1, 2, 8" do
  let(:helper) { CrossAggregateHelper.new }

  describe "chain 1 : LucidRemEntered → LucidDream.BecomeLucid" do
    it "fires BecomeLucid via BecomeLucidOnFinalRem policy" do
      # Seed Body in the final cycle's light phase — the only state in
      # which AdvanceLightToLucidRem (and thus LucidRemEntered) fires.
      helper.seed_consciousness(
        state: "sleeping", sleep_stage: "light",
        sleep_cycle: 8, sleep_total: 8,
      )
      helper.step("AdvanceLightToLucidRem")

      # Source event emitted.
      expect(helper.emitted?("LucidRemEntered")).to be(true)
      # Policy-driven cascade : BecomeLucid landed on LucidDream.
      expect(helper.lucid_attr(:active)).to eq("yes")
      # Policy chain emitted BecameLucid as proof of the cascade hop.
      expect(helper.emitted?("BecameLucid")).to be(true)
    end
  end

  describe "chain 2 : DeepEntered → LucidDream.EndLucidity" do
    it "fires EndLucidity via EndLucidityOnDeep policy" do
      # Set up the body mid-final-REM with dream_pulses ready to advance.
      # AdvanceRemToDeep gate : dream_pulses >= dream_pulses_needed.
      helper.seed_consciousness(
        state: "sleeping", sleep_stage: "rem",
        sleep_cycle: 8, sleep_total: 8,
        dream_pulses: 8, dream_pulses_needed: 8,
        is_lucid: "yes",
      )
      # Pre-establish lucidity so the EndLucidity transition is observable.
      helper.step("BecomeLucid", onset_narrative: "I realize I'm dreaming")
      expect(helper.lucid_attr(:active)).to eq("yes")

      helper.step("AdvanceRemToDeep")

      expect(helper.emitted?("DeepEntered")).to be(true)
      expect(helper.lucid_attr(:active)).to eq("no")
      expect(helper.emitted?("LucidityEnded")).to be(true)
    end

    it "EndLucidity is idempotent : DeepEntered fires from a non-lucid REM too without error" do
      # Even when the prior REM was non-lucid, DeepEntered must still
      # cascade safely. The policy comment in lucid_dream.bluebook calls
      # this out explicitly : "EndLucidity is idempotent : safe to call
      # when not lucid". This guards against the dispatch wrapper raising.
      helper.seed_consciousness(
        state: "sleeping", sleep_stage: "rem",
        sleep_cycle: 1, sleep_total: 8,
        dream_pulses: 5, dream_pulses_needed: 5,
        is_lucid: "no",
      )
      expect { helper.step("AdvanceRemToDeep") }.not_to raise_error
      expect(helper.emitted?("DeepEntered")).to be(true)
      # LucidityEnded still fires (policy is event-driven, not state-driven).
      expect(helper.emitted?("LucidityEnded")).to be(true)
    end
  end

  describe "chain 8 : Witness.ReflectOnObservation → Dream.BecomeLucid" do
    # The policy is declared `LucidOnReflection across "Dream"` in
    # witness.bluebook. `across "Dream"` is the cross-bluebook fanout
    # marker. Today the audit notes the single-bluebook .behaviors
    # runner can't follow `across` hops ; the BehaviorRuntime in this
    # helper composes all bluebooks into one runtime, so the cascade
    # CAN be asserted here.

    it "fires BecomeLucid on the dream/lucid aggregate via the meta-awareness bridge" do
      # First-order observation, then second-order reflection.
      helper.step("Observe", observing: "the dream of being lucid")
      helper.step("ReflectOnObservation",
                  witness: "1",
                  insight: "I'm aware that I'm aware")

      expect(helper.emitted?("ReflectionOccurred")).to be(true)
      # The lucidity bridge fires : LucidDream.active flips to yes.
      expect(helper.lucid_attr(:active)).to eq("yes")
      expect(helper.emitted?("BecameLucid")).to be(true)
    end
  end
end

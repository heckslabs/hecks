# synapse_math_spec.rb — Phase 0g invariants 1-4
#
# Locks the numeric math of the four Synapse mutations (i106 in-DSL
# math primitives + i203 dispatch-by-id). The audit found the existing
# body/organs/synapse.behaviors tests command-shape only — not the
# numeric deltas, not the clamps. A refactor that drifts +0.02 to +0.01
# (or removes the clamp) would slip past the existing suite ; these
# invariants catch it.
#
# Invariants asserted :
#   1. StrengthenSynapse — strength += 0.02, clamped to [0, 1]
#      a. seed 0.5 → 0.52
#      b. seed 0.99 → 1.0  (clamp upper bound)
#   2. DecaySynapse — strength *= 0.98, clamped to [0, 1]
#      a. seed 0.5 → 0.49
#      b. seed 0.001 → 0.00098  (no negative ; near-zero stays positive)
#   3. Compost — state → composted (transition, no math drift)
#      a. seed strength=0.05 → state=composted
#   4. FireSynapse — firings += 1, last_fired_at stamped to passed value
#      a. seed firings=0 + last_fired_at="old" ; dispatch with NOW ;
#         expect firings=1 + last_fired_at=NOW
#
# Production reference :
#   body/organs/synapse.bluebook (StrengthenSynapse / DecaySynapse /
#   FireSynapse / Compost commands)

require_relative "spec_helper"

RSpec.describe "Synapse math invariants (i106 + i203)" do
  before(:all) do
    skip DispatchHelper.skip_reason unless DispatchHelper.ready?
  end

  let(:helper) { DispatchHelper.new }

  describe "invariant 1 : StrengthenSynapse += 0.02 + clamp" do
    it "(1a) increments 0.5 to 0.52" do
      helper.with_isolated_info do
        id = helper.seed("synapse/synapse.heki",
                         from: "A", to: "B", strength: 0.5,
                         state: "alive", firings: 0, last_fired_at: "now")
        state = helper.dispatch("Synapse.StrengthenSynapse", synapse: id)
        expect(state.fetch("strength").to_f).to be_within(1e-9).of(0.52)
      end
    end

    it "(1b) clamps to 1.0 when starting at 0.99" do
      helper.with_isolated_info do
        id = helper.seed("synapse/synapse.heki",
                         from: "A", to: "B", strength: 0.99,
                         state: "alive", firings: 0, last_fired_at: "now")
        state = helper.dispatch("Synapse.StrengthenSynapse", synapse: id)
        expect(state.fetch("strength").to_f).to eq(1.0)
        expect(state.fetch("strength").to_f).to be <= 1.0
      end
    end
  end

  describe "invariant 2 : DecaySynapse *= 0.98 + clamp" do
    it "(2a) decays 0.5 to 0.49" do
      helper.with_isolated_info do
        id = helper.seed("synapse/synapse.heki",
                         from: "A", to: "B", strength: 0.5,
                         state: "alive", firings: 0, last_fired_at: "now")
        state = helper.dispatch("Synapse.DecaySynapse", synapse: id)
        expect(state.fetch("strength").to_f).to be_within(1e-9).of(0.49)
      end
    end

    it "(2b) decays 0.001 to 0.00098 (still positive, not clamped to 0)" do
      helper.with_isolated_info do
        id = helper.seed("synapse/synapse.heki",
                         from: "A", to: "B", strength: 0.001,
                         state: "alive", firings: 0, last_fired_at: "now")
        state = helper.dispatch("Synapse.DecaySynapse", synapse: id)
        result = state.fetch("strength").to_f
        expect(result).to be_within(1e-9).of(0.00098)
        expect(result).to be > 0.0
      end
    end
  end

  describe "invariant 3 : Compost transitions state at low strength" do
    it "(3) seed strength=0.05 + dispatch Compost → state=composted" do
      helper.with_isolated_info do
        id = helper.seed("synapse/synapse.heki",
                         from: "A", to: "B", strength: 0.05,
                         state: "alive", firings: 0, last_fired_at: "now")
        state = helper.dispatch("Synapse.Compost", synapse: id)
        expect(state.fetch("state")).to eq("composted")
      end
    end
  end

  describe "invariant 4 : FireSynapse increments firings + stamps last_fired_at" do
    it "(4) seed firings=0 ; dispatch with NOW ; firings=1 + last_fired_at=NOW" do
      now_iso = "2026-05-01T12:34:56Z"
      helper.with_isolated_info do
        id = helper.seed("synapse/synapse.heki",
                         from: "A", to: "B", strength: 0.5,
                         state: "alive", firings: 0,
                         last_fired_at: "1970-01-01T00:00:00Z")
        state = helper.dispatch("Synapse.FireSynapse",
                                synapse: id, last_fired_at: now_iso)
        expect(state.fetch("firings").to_i).to eq(1)
        expect(state.fetch("last_fired_at")).to eq(now_iso)
      end
    end
  end
end

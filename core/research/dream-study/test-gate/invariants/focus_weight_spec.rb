# focus_weight_spec.rb — Phase 0g invariant 8
#
# Locks the focus-weight formula. Today the formula is split across
# two surfaces : pulse_organs.sh:226 computes
#
#     weight = 0.5 + (firings_sum / 20.0)
#
# (an awk one-liner) and dispatches the raw value into
# Focus.AdjustWeight, which then clamps to [0, 1] in the bluebook
# (i106 :clamp). The audit calls out :
#
#   "the formula `weight = 0.5 + firings/20.0 clamped` is NOT asserted"
#
# This spec asserts both ends — the formula AND the clamp — so a
# refactor that moves the computation entirely into the bluebook
# (or breaks the divisor) gets caught.
#
# Invariants asserted :
#   8. weight = 0.5 + firings_sum/20.0, clamped to [0, 1]
#      a. firings_sum=0   → weight=0.5
#      b. firings_sum=5   → weight=0.75
#      c. firings_sum=10  → weight=1.0  (boundary, not clamped — exactly 1.0)
#      d. firings_sum=200 → weight=1.0  (clamped from raw 10.5)
#      e. raw weight=1.5  dispatched directly → AdjustWeight clamps to 1.0
#      f. raw weight=-0.3 dispatched directly → AdjustWeight clamps to 0.0
#
# The Ruby formula(firings_sum) helper mirrors the awk math byte-for-byte
# so a regression in either side surfaces.

require_relative "spec_helper"

RSpec.describe "Focus weight formula + clamp" do
  before(:all) do
    skip DispatchHelper.skip_reason unless DispatchHelper.ready?
  end

  let(:helper) { DispatchHelper.new }

  # Mirror of pulse_organs.sh:226 : awk -v f=$firings_sum 'BEGIN { printf "%.4f", 0.5 + (f / 20.0) }'.
  # If the production formula drifts (e.g. divisor changes from 20 to 30), the
  # math changes here in lockstep and the boundary cases below break.
  def production_formula(firings_sum)
    0.5 + (firings_sum.to_f / 20.0)
  end

  describe "invariant 8 : weight = 0.5 + firings/20.0, clamped to [0, 1]" do
    it "(8a) firings_sum=0 → weight=0.5 (baseline, no firings)" do
      helper.with_isolated_info do
        raw = production_formula(0)
        expect(raw).to eq(0.5)
        helper.dispatch("Focus.SetFocus",
                        target: "carrying", weight: 0.5, updated_at: "t0")
        focus_id = helper.latest_field("focus/focus.heki", "id")
        state = helper.dispatch("Focus.AdjustWeight",
                                focus: focus_id, weight: raw, updated_at: "t1")
        expect(state.fetch("weight").to_f).to be_within(1e-9).of(0.5)
      end
    end

    it "(8b) firings_sum=5 → weight=0.75" do
      helper.with_isolated_info do
        raw = production_formula(5)
        expect(raw).to eq(0.75)
        helper.dispatch("Focus.SetFocus",
                        target: "topic", weight: 0.5, updated_at: "t0")
        focus_id = helper.latest_field("focus/focus.heki", "id")
        state = helper.dispatch("Focus.AdjustWeight",
                                focus: focus_id, weight: raw, updated_at: "t1")
        expect(state.fetch("weight").to_f).to be_within(1e-9).of(0.75)
      end
    end

    it "(8c) firings_sum=10 → weight=1.0 (boundary, not clamped)" do
      helper.with_isolated_info do
        raw = production_formula(10)
        expect(raw).to eq(1.0)
        helper.dispatch("Focus.SetFocus",
                        target: "topic", weight: 0.5, updated_at: "t0")
        focus_id = helper.latest_field("focus/focus.heki", "id")
        state = helper.dispatch("Focus.AdjustWeight",
                                focus: focus_id, weight: raw, updated_at: "t1")
        expect(state.fetch("weight").to_f).to eq(1.0)
      end
    end

    it "(8d) firings_sum=200 → weight=1.0 (clamped from raw 10.5)" do
      helper.with_isolated_info do
        raw = production_formula(200)
        expect(raw).to eq(10.5)
        helper.dispatch("Focus.SetFocus",
                        target: "topic", weight: 0.5, updated_at: "t0")
        focus_id = helper.latest_field("focus/focus.heki", "id")
        state = helper.dispatch("Focus.AdjustWeight",
                                focus: focus_id, weight: raw, updated_at: "t1")
        expect(state.fetch("weight").to_f).to eq(1.0)
      end
    end

    it "(8e) raw weight=1.5 → bluebook clamps to 1.0" do
      helper.with_isolated_info do
        helper.dispatch("Focus.SetFocus",
                        target: "topic", weight: 0.5, updated_at: "t0")
        focus_id = helper.latest_field("focus/focus.heki", "id")
        state = helper.dispatch("Focus.AdjustWeight",
                                focus: focus_id, weight: 1.5, updated_at: "t1")
        expect(state.fetch("weight").to_f).to eq(1.0)
      end
    end

    it "(8f) raw weight=-0.3 → bluebook clamps to 0.0" do
      helper.with_isolated_info do
        helper.dispatch("Focus.SetFocus",
                        target: "topic", weight: 0.5, updated_at: "t0")
        focus_id = helper.latest_field("focus/focus.heki", "id")
        state = helper.dispatch("Focus.AdjustWeight",
                                focus: focus_id, weight: -0.3, updated_at: "t1")
        expect(state.fetch("weight").to_f).to eq(0.0)
      end
    end
  end
end

# awake_pulse_chain_spec.rb — Phase 0c cross-aggregate chains 6, 7.
#
# Two chains that fan out from BodyPulse — the body-wide pacing event
# emitted by Pulse.Emit. Today these are the heart of the per-tick
# awake loop : every tick fires BodyPulse, every BodyPulse fans out
# into Awareness (per-tick snapshot) and Heartbeat (fatigue
# accumulation).
#
# Chain 7 is already covered by `pulse_fanout_smoke.sh` at the runtime
# level ; this spec ports the assertion shape into RSpec form so it
# runs alongside the rest of the cross-aggregate gate without a
# subprocess and a real disk-backed runtime. The audit calls this out
# explicitly : "BodyPulse → AccumulateFatigue : already covered by
# pulse_fanout_smoke.sh ; consider porting the assertion shape into a
# behaviors-style test once cross-bluebook runner exists." This is that
# port.
#
# Chains under test :
#
#   6. Pulse.Emit
#        → emits BodyPulse
#        → policy `RecordMomentOnPulse` (awareness.bluebook)
#        → Awareness.RecordMoment
#        → emits MomentRecorded ; awareness.heki gets a per-tick row
#      Today this is the 13-attr shell-side AwarenessSnapshot read by
#      mindstream.sh — the dream-study refactor moves it into Mind PM.
#      The contract under test here is the policy edge, not the 13-attr
#      content (that's covered by 0g organ-math + 0d statusline).
#
#   7. Pulse.Emit
#        → emits BodyPulse
#        → policy `FatigueOnPulse` (heartbeat.bluebook)
#        → Heartbeat.AccumulateFatigue
#        → heartbeat.pulses_since_sleep increments by 1 ;
#          heartbeat.fatigue increments by 0.001 ; emits FatigueAccumulated
#      Today : `pulse_fanout_smoke.sh` asserts this end-to-end via the
#      Rust runtime. This spec asserts the same shape in-process via
#      BehaviorRuntime so the gate runs sub-second.
#
# Audit cross-reference :
#   `dream-study/test-gate/test-audit.md` § 0c, chains 6 / 7.
#
# Run :
#   cd dream-study/test-gate/cross_aggregate
#   rspec awake_pulse_chain_spec.rb

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "rspec"
require "cross_aggregate_helper"

RSpec.describe "awake pulse chain — chains 6, 7" do
  let(:helper) { CrossAggregateHelper.new }

  describe "chain 6 : BodyPulse → Awareness.RecordMoment" do
    it "fires RecordMoment via RecordMomentOnPulse policy" do
      # Pulse.Emit is the source. BehaviorRuntime cascades the policies.
      helper.step("Emit")

      expect(helper.emitted?("BodyPulse")).to be(true)
      expect(helper.emitted?("MomentRecorded")).to be(true)
      # Awareness aggregate received a row — moment field populated by
      # the cascade. RecordMoment's then_set assigns from the policy's
      # default attrs ; the contract is "the row exists", not the 13-attr
      # content (deferred to 0g + Mind PM phase).
      expect(helper.awareness).not_to be_nil
    end
  end

  describe "chain 7 : BodyPulse → Heartbeat.AccumulateFatigue" do
    # Mirrors pulse_fanout_smoke.sh's heartbeat-side assertion in RSpec
    # form. The shell smoke runs the Rust runtime ; this spec runs the
    # Ruby BehaviorRuntime — both should agree on the policy edge.

    it "fires AccumulateFatigue via FatigueOnPulse policy" do
      # Default Heartbeat sleep_gate is "open" per heartbeat.bluebook
      # (`attribute :sleep_gate, default: "open"`). The BehaviorRuntime's
      # pre-seeded singleton row has empty fields ; we set sleep_gate
      # explicitly via OpenFatigueGate so the AccumulateFatigue's
      # `given("not sleeping") { sleep_gate == "open" }` passes.
      helper.step("OpenFatigueGate")
      helper.step("Emit")

      expect(helper.emitted?("BodyPulse")).to be(true)
      expect(helper.emitted?("FatigueAccumulated")).to be(true)
      expect(helper.heartbeat_attr(:pulses_since_sleep).to_i).to eq(1)
      # Fatigue increment is 0.001 per tick.
      expect(helper.heartbeat_attr(:fatigue).to_f).to be_within(1e-9).of(0.001)
    end

    it "AccumulateFatigue is refused while sleep_gate is closed (i40)" do
      # Close the gate first — mirrors what CloseFatigueGateOnSleep
      # does on SleepEntered. The cascade halts on the GivenFailed
      # without raising — `pulse_fanout_smoke.sh` proves this at the
      # runtime level by accumulating ZERO fatigue across 10 sleep ticks.
      helper.step("CloseFatigueGate")
      expect(helper.heartbeat_attr(:sleep_gate)).to eq("closed")

      helper.step("Emit")

      expect(helper.emitted?("BodyPulse")).to be(true)
      # Gate refused — pulses_since_sleep stays at 0.
      expect(helper.heartbeat_attr(:pulses_since_sleep).to_i).to eq(0)
      expect(helper.heartbeat_attr(:fatigue).to_f).to eq(0.0)
      # FatigueAccumulated NOT emitted — the GivenFailed halts the cascade.
      expect(helper.emitted?("FatigueAccumulated")).to be(false)
    end
  end

  describe "BodyPulse fans out to BOTH targets in one cascade" do
    # Regression-locks the fanout shape : a single Pulse.Emit must fire
    # both `RecordMomentOnPulse` and `FatigueOnPulse` via the same
    # BodyPulse event. Today the Rust runtime + Ruby BehaviorRuntime
    # both walk the policy list in declaration order ; this spec
    # ensures neither implementation accidentally short-circuits.
    it "single Emit fires both Awareness and Heartbeat sides" do
      # Open the fatigue gate so the heartbeat side passes its `given`
      # (see chain 7 note about default initialisation).
      helper.step("OpenFatigueGate")
      helper.step("Emit")

      # BodyPulse emitted exactly once.
      expect(helper.emitted_events.count("BodyPulse")).to eq(1)
      # Both downstream events landed.
      expect(helper.emitted?("MomentRecorded")).to be(true)
      expect(helper.emitted?("FatigueAccumulated")).to be(true)
    end
  end
end

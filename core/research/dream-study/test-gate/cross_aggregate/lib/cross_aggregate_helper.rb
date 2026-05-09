# CrossAggregateHelper
#
# Boots a composite Hecks::Behaviors::BehaviorRuntime over the bluebooks
# that participate in cross-aggregate event chains today, then exposes a
# tiny `step + snapshot + emitted_events` API the cross_aggregate specs
# use to drive single-step dispatches and observe the cascade.
#
# Mirrors the shape of end_to_end/lib/sleep_cycle_helper.rb (Phase 0b)
# but is wider and shallower — it loads more bluebooks (because the
# chains span Pulse, Awareness, Witness, Dream/LucidDream, Mood,
# Heartbeat, WakeMood, Consciousness) and never drives a full cycle.
#
# Each spec dispatches one source command, then asserts that target
# aggregates received the cascading policy-driven command. Where a
# policy doesn't currently exist (chain 3 : DeepEntered→RecoverFatigue ;
# chain 5 : WokenUp→WakeMood.SetWakeMood), the spec skips with a clear
# inbox-ready reason via RSpec `pending` so the assertion stays in the
# tree and turns green the moment the policy lands.
#
# Usage :
#
#   helper = CrossAggregateHelper.new
#   helper.step("Consciousness.EnterSleep", sleep_at: "2026-05-01T22:00:00Z")
#   expect(helper.heartbeat_attr(:sleep_gate)).to eq("closed")
#   expect(helper.emitted?("FatigueGateClosed")).to be(true)

require "hecks"
require "hecks/behaviors/behavior_runtime"
require "hecks/behaviors/aggregate_state"
require "hecks/behaviors/value"

class CrossAggregateHelper
  # __dir__ = .../dream-study/test-gate/cross_aggregate/lib ; miette root is 4 ↑.
  MIETTE_ROOT = File.expand_path("../../../..", __dir__)

  # Bluebooks loaded into the composite runtime. Chosen narrow enough
  # that each spec's dispatch resolves without unrelated cascade noise,
  # wide enough that every chain under test has its source AND target
  # aggregate present.
  BLUEBOOKS = [
    "body/sleep/consciousness.bluebook",   # Body / Consciousness — source of LucidRemEntered, DeepEntered, WokenUp
    "body/sleep/wake_mood.bluebook",       # WakeMood — chain 5 target
    "body/dream/lucid_dream.bluebook",     # LucidDream — chain 1, 2, 8 target
    "body/cycles/heartbeat.bluebook",      # Heartbeat — chain 3, 4, 7 target
    "body/cycles/pulse.bluebook",          # Pulse.Emit emits BodyPulse — chain 6, 7 source
    "mind/awareness/awareness.bluebook",   # Awareness — chain 6 target
    "mind/awareness/witness.bluebook",     # Witness — chain 8 source
    "mind/state/mood.bluebook",            # Mood — production wake-mood chain target (RefreshMood / SetGroggy)
  ].freeze

  attr_reader :runtime, :transitions

  def initialize
    @runtime     = boot_runtime
    @transitions = []
  end

  # ---- Aggregate accessors --------------------------------------------------

  def consciousness; runtime.find("Consciousness", "1"); end
  def heartbeat;     runtime.find("Heartbeat",     "1"); end
  def lucid_dream;   runtime.find("LucidDream",    "1"); end
  def wake_mood;     runtime.find("WakeMood",      "1"); end
  def mood;          runtime.find("Mood",          "1"); end
  def awareness;     runtime.find("Awareness",     "1"); end
  def witness;       runtime.find("Witness",       "1"); end
  def pulse;         runtime.find("Pulse",         "1"); end

  # Read one attribute off any singleton-shaped aggregate. The chain
  # specs use these to assert that the target aggregate received the
  # cascading command (e.g. heartbeat.sleep_gate flipped to "closed").
  def attr_of(agg_name, field)
    rec = runtime.find(agg_name.to_s, "1")
    return nil unless rec
    f = rec.fields[field.to_s]
    f && f.to_display
  end

  def heartbeat_attr(f);   attr_of("Heartbeat", f);   end
  def lucid_attr(f);       attr_of("LucidDream", f);  end
  def awareness_attr(f);   attr_of("Awareness", f);   end
  def witness_attr(f);     attr_of("Witness", f);     end
  def wake_mood_attr(f);   attr_of("WakeMood", f);    end
  def mood_attr(f);        attr_of("Mood", f);        end
  def consciousness_attr(f); attr_of("Consciousness", f); end

  # ---- Event introspection --------------------------------------------------

  # All event names emitted into the runtime's event_bus across every
  # `step` call so far. Specs use this to prove the policy chain fired
  # (e.g. emitted?("FatigueGateClosed") after EnterSleep).
  def emitted_events
    runtime.event_bus.map { |e| e[:name] }
  end

  def emitted?(name)
    emitted_events.include?(name.to_s)
  end

  # ---- Step / dispatch ------------------------------------------------------

  # Dispatches +command+ via the cascading dispatcher. Records the
  # (command, attrs) pair so the spec can introspect the call sequence.
  # Returns the runtime for chaining ; specs typically read attrs after.
  def step(command, **attrs)
    value_attrs = attrs.transform_values { |v| Hecks::Behaviors::Value.from(v) }
                       .transform_keys(&:to_s)
    runtime.dispatch(command, value_attrs)
    @transitions << { command: command, attrs: attrs }
    runtime
  end

  # Convenience for "the body is sleeping at the end of cycle N" setups.
  # Used by the LucidRemEntered + DeepEntered chain specs to skip the
  # boring 7-cycle wind-up before the assertion-relevant transition.
  def seed_consciousness(state:, sleep_stage:, sleep_cycle: 1, sleep_total: 8,
                         dream_pulses: 0, dream_pulses_needed: 5,
                         is_lucid: "no", phase_ticks: 0,
                         last_sleep_entered_at: "2026-05-01T22:00:00Z",
                         last_wake_at: "")
    rec = runtime.find("Consciousness", "1")
    rec.fields["state"]                 = Hecks::Behaviors::Value.from(state)
    rec.fields["sleep_stage"]           = Hecks::Behaviors::Value.from(sleep_stage)
    rec.fields["sleep_cycle"]           = Hecks::Behaviors::Value.from(sleep_cycle)
    rec.fields["sleep_total"]           = Hecks::Behaviors::Value.from(sleep_total)
    rec.fields["dream_pulses"]          = Hecks::Behaviors::Value.from(dream_pulses)
    rec.fields["dream_pulses_needed"]   = Hecks::Behaviors::Value.from(dream_pulses_needed)
    rec.fields["is_lucid"]              = Hecks::Behaviors::Value.from(is_lucid)
    rec.fields["phase_ticks"]           = Hecks::Behaviors::Value.from(phase_ticks)
    rec.fields["last_sleep_entered_at"] = Hecks::Behaviors::Value.from(last_sleep_entered_at)
    rec.fields["last_wake_at"]          = Hecks::Behaviors::Value.from(last_wake_at)
    rec.fields["name"]                  = Hecks::Behaviors::Value.from("consciousness")
  end

  private

  def boot_runtime
    aggregates = []
    policies   = []
    BLUEBOOKS.each do |relative|
      path = File.join(MIETTE_ROOT, relative)
      raise "missing bluebook : #{path}" unless File.file?(path)
      Hecks.instance_variable_set(:@last_domain, nil)
      Kernel.load(path)
      d = Hecks.last_domain
      raise "no domain produced by #{relative}" unless d
      aggregates.concat(d.aggregates)
      policies.concat(d.policies)
    end

    domain = Hecks::BluebookModel::Structure::Domain.new(
      name:       "DreamStudyCrossAggregate",
      aggregates: aggregates,
      policies:   policies,
    )
    rt = Hecks::Behaviors::BehaviorRuntime.boot(domain)
    # Pre-seed every aggregate as a singleton at id "1" — mirrors the
    # behaviors runner's pre_seed_singletons logic. Every aggregate in
    # this slice is identified_by :name with a single row.
    domain.aggregates.each do |agg|
      rt.repositories[agg.name]["1"] = Hecks::Behaviors::AggregateState.new("1")
    end
    rt
  end
end

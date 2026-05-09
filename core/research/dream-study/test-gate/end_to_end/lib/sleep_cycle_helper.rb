# SleepCycleHelper
#
# Boots a composite Hecks::Behaviors::BehaviorRuntime over the five
# bluebooks that participate in Miette's sleep cycle today :
#
#   - body/sleep/consciousness.bluebook   (Consciousness aggregate, lifecycle)
#   - body/dream/lucid_dream.bluebook     (LucidDream + lucid policies)
#   - body/sleep/wake_mood.bluebook       (WakeMood snapshot aggregate)
#   - body/cycles/heartbeat.bluebook      (Heartbeat fatigue + sleep gate)
#   - mind/state/mood.bluebook            (Mood — refreshed/groggy via WokeX)
#
# It then drives a full 8-cycle sleep without waiting on real time : every
# advancement command is dispatched directly. The helper records a triple
# (event, command, state-after) for every transition so the spec can
# assert on the entire sequence.
#
# This is the Phase 0b regression contract — every subsequent dream-study
# PR must keep the resulting sequence intact.
#
# Usage :
#   helper = SleepCycleHelper.new
#   helper.run_full_cycle(sleep_at: "2026-05-01T22:00:00Z",
#                         wake_at:  "2026-05-02T06:00:00Z")
#   helper.consciousness  # => AggregateState
#   helper.heartbeat      # => AggregateState
#   helper.lucid_dream    # => AggregateState
#   helper.mood           # => AggregateState
#   helper.transitions    # => [{stage:, cycle:, after:, ...}, ...]

require "hecks"
require "hecks/behaviors/behavior_runtime"
require "hecks/behaviors/aggregate_state"
require "hecks/behaviors/value"

class SleepCycleHelper
  # __dir__ = .../dream-study/test-gate/end_to_end/lib ; miette root is 4 ↑.
  MIETTE_ROOT = File.expand_path("../../../..", __dir__)

  BLUEBOOKS = [
    "body/sleep/consciousness.bluebook",
    "body/dream/lucid_dream.bluebook",
    "body/sleep/wake_mood.bluebook",
    "body/cycles/heartbeat.bluebook",
    "mind/state/mood.bluebook",
  ].freeze

  REGULAR_REM_PULSES = 5
  LUCID_REM_PULSES   = 8
  TOTAL_CYCLES       = 8

  attr_reader :runtime, :transitions

  def initialize
    @runtime     = boot_runtime
    @transitions = []
  end

  def consciousness; runtime.find("Consciousness", "1"); end
  def heartbeat;     runtime.find("Heartbeat",     "1"); end
  def lucid_dream;   runtime.find("LucidDream",    "1"); end
  def wake_mood;     runtime.find("WakeMood",      "1"); end
  def mood;          runtime.find("Mood",          "1"); end

  # Reads a Consciousness attribute's display string.
  def consciousness_attr(name)
    f = consciousness&.fields&.[](name.to_s)
    f && f.to_display
  end

  # Snapshot the aggregates whose state the contract asserts on. Used
  # both for transition logging and final-state assertions.
  def snapshot
    {
      state:                  consciousness_attr(:state),
      sleep_stage:            consciousness_attr(:sleep_stage),
      sleep_cycle:            consciousness_attr(:sleep_cycle),
      sleep_total:            consciousness_attr(:sleep_total),
      dream_pulses:           consciousness_attr(:dream_pulses),
      dream_pulses_needed:    consciousness_attr(:dream_pulses_needed),
      is_lucid:               consciousness_attr(:is_lucid),
      sleep_summary:          consciousness_attr(:sleep_summary),
      last_sleep_entered_at:  consciousness_attr(:last_sleep_entered_at),
      last_wake_at:           consciousness_attr(:last_wake_at),
      heartbeat_sleep_gate:   heartbeat&.fields&.[]("sleep_gate")&.to_display,
      heartbeat_fatigue:      heartbeat&.fields&.[]("fatigue")&.to_display,
      heartbeat_fatigue_state: heartbeat&.fields&.[]("fatigue_state")&.to_display,
      lucid_active:           lucid_dream&.fields&.[]("active")&.to_display,
      mood_current_state:     mood&.fields&.[]("current_state")&.to_display,
    }
  end

  # Dispatches +command+ with +attrs+ via the cascading dispatcher and
  # records a (command, attrs, snapshot) triple. Returns the snapshot.
  def step(command, **attrs)
    value_attrs = attrs.transform_values { |v| Hecks::Behaviors::Value.from(v) }
                       .transform_keys(&:to_s)
    runtime.dispatch(command, value_attrs)
    snap = snapshot
    @transitions << { command: command, attrs: attrs, after: snap }
    snap
  end

  # Drives the full 8-cycle sleep from EnterSleep to natural wake.
  # No real-time waiting — every gate advances by direct dispatch.
  def run_full_cycle(sleep_at:, wake_at:)
    step("EnterSleep", sleep_at: sleep_at)

    1.upto(TOTAL_CYCLES - 1) do |cycle|
      step("AdvanceLightToRem")
      REGULAR_REM_PULSES.times do |i|
        step("DreamPulse", impression: "cycle-#{cycle}-pulse-#{i + 1}")
      end
      step("AdvanceRemToDeep")
      step("AdvanceDeepToLight")
    end

    # Cycle 8 — lucid path with 8 pulses + final light.
    step("AdvanceLightToLucidRem")
    LUCID_REM_PULSES.times do |i|
      step("DreamPulse", impression: "lucid-pulse-#{i + 1}")
    end
    step("AdvanceRemToDeep")
    step("AdvanceDeepToFinalLight")
    step("CompleteFinalLight", wake_at: wake_at)
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
      name:       "DreamStudyTestGate",
      aggregates: aggregates,
      policies:   policies,
    )
    rt = Hecks::Behaviors::BehaviorRuntime.boot(domain)
    # Pre-seed every aggregate as a singleton at id "1" — mirrors the
    # behaviors runner's pre_seed_singletons logic, simpler because
    # every aggregate in this slice is identified_by :name with one row.
    domain.aggregates.each do |agg|
      rt.repositories[agg.name]["1"] = Hecks::Behaviors::AggregateState.new("1")
    end
    rt
  end
end

# FullNightHelper
#
# Composite BehaviorRuntime over the bluebooks that drive Miette's
# 8-cycle sleep PLUS the cross-aggregate fan-out (Pulse, Awareness,
# Witness) so the full-night spec can assert every chain in one run.
#
# Loaded bluebooks :
#   body/sleep/consciousness.bluebook   — Body / Consciousness state machine
#   body/dream/lucid_dream.bluebook     — LucidDream + lucid policies
#   body/sleep/wake_mood.bluebook       — WakeMood snapshot aggregate
#   body/cycles/heartbeat.bluebook      — Heartbeat fatigue + sleep gate
#   body/cycles/pulse.bluebook          — Pulse.Emit emits BodyPulse
#   mind/awareness/awareness.bluebook   — Awareness (records moment on pulse)
#   mind/awareness/witness.bluebook     — Witness (mirrors body events)
#   mind/state/mood.bluebook            — Mood (refreshed via WokeFullSleep)
#   body/wake/wake_report.bluebook      — WakeReport (StartReport on full wake)
#
# DI seam — FixtureLlmAdapter
#   The production :llm adapter doesn't exist yet (Phase 0h gap). This
#   helper threads dream content from the FixtureLlmAdapter at the
#   test-fixture boundary : when the spec wants to fire one dream pulse,
#   it asks the helper for `dream_pulse(cycle:, pulse:)` (regular) or
#   `lucid_pulse(cycle:, pulse:)` (lucid REM). The helper fetches the
#   canned text and dispatches the appropriate command :
#
#     - regular REM : Consciousness.DreamPulse(impression: text_en)
#                     + LucidDream.ObserveDream is NOT called (no
#                     lucidity), but the impression is still recorded.
#     - lucid  REM  : Consciousness.DreamPulse(impression: text_en)
#                     + LucidDream.ObserveDream(observation: text_en)
#                     so the lucid observations list captures the dream.
#
#   The state machine flows through the runtime as in Phase 0b ; the
#   dream content flows from the fixture. This is exactly the seam
#   Phase 4-7 specs will hook into when the production :llm adapter
#   ships — the FixtureLlmAdapter's surface is stable.
#
# TestClock
#   A 30-line fake (TestClock class below) that advances dream pulses by
#   programmatic `tick!`. BehaviorRuntime today has no real cadence
#   adapter ; tick! is just `helper.dream_pulse(...)` under a friendlier
#   name + a monotonic counter for assertions.
#
# Usage :
#   helper = FullNightHelper.new(fixture_path: FIXTURE_PATH)
#   helper.run_full_night(sleep_at: "...", wake_at: "...")
#   helper.snapshot
#   helper.dream_images          # => list of english impressions threaded
#                                #    through (43 entries on a full night)
#   helper.transitions           # => command/attrs/snapshot triples
#   helper.clock.ticks           # => 43 (one per dream pulse)

require "hecks"
require "hecks/behaviors/behavior_runtime"
require "hecks/behaviors/aggregate_state"
require "hecks/behaviors/value"
require "hecks/adapters/fixture_llm_adapter"

class FullNightHelper
  # __dir__ = .../dream-study/test-gate/in_memory_full_night/lib ; miette root is 4 ↑.
  MIETTE_ROOT = File.expand_path("../../../..", __dir__)

  BLUEBOOKS = [
    "body/sleep/consciousness.bluebook",
    "body/dream/lucid_dream.bluebook",
    "body/sleep/wake_mood.bluebook",
    "body/cycles/heartbeat.bluebook",
    "body/cycles/pulse.bluebook",
    "mind/awareness/awareness.bluebook",
    "mind/awareness/witness.bluebook",
    "mind/state/mood.bluebook",
    "body/wake/wake_report.bluebook",
  ].freeze

  REGULAR_REM_PULSES = 5
  LUCID_REM_PULSES   = 8
  TOTAL_CYCLES       = 8

  attr_reader :runtime, :transitions, :dream_images, :llm, :clock

  def initialize(fixture_path:)
    @llm          = Hecks::Adapters::FixtureLlmAdapter.from_yaml(fixture_path)
    @clock        = TestClock.new
    @runtime      = boot_runtime
    @transitions  = []
    @dream_images = []
  end

  # ---- Aggregate accessors -----------------------------------------------

  def consciousness; runtime.find("Consciousness", "1"); end
  def heartbeat;     runtime.find("Heartbeat",     "1"); end
  def lucid_dream;   runtime.find("LucidDream",    "1"); end
  def wake_mood;     runtime.find("WakeMood",      "1"); end
  def mood;          runtime.find("Mood",          "1"); end
  def witness;       runtime.find("Witness",       "1"); end

  def attr_of(agg_name, field)
    rec = runtime.find(agg_name.to_s, "1")
    return nil unless rec
    f = rec.fields[field.to_s]
    f && f.to_display
  end

  def snapshot
    {
      state:                  attr_of("Consciousness", :state),
      sleep_stage:            attr_of("Consciousness", :sleep_stage),
      sleep_cycle:            attr_of("Consciousness", :sleep_cycle),
      sleep_total:            attr_of("Consciousness", :sleep_total),
      dream_pulses:           attr_of("Consciousness", :dream_pulses),
      dream_pulses_needed:    attr_of("Consciousness", :dream_pulses_needed),
      is_lucid:               attr_of("Consciousness", :is_lucid),
      sleep_summary:          attr_of("Consciousness", :sleep_summary),
      last_sleep_entered_at:  attr_of("Consciousness", :last_sleep_entered_at),
      last_wake_at:           attr_of("Consciousness", :last_wake_at),
      heartbeat_sleep_gate:   attr_of("Heartbeat", :sleep_gate),
      heartbeat_fatigue:      attr_of("Heartbeat", :fatigue),
      heartbeat_fatigue_state: attr_of("Heartbeat", :fatigue_state),
      lucid_active:           attr_of("LucidDream", :active),
      lucid_latest_narrative: attr_of("LucidDream", :latest_narrative),
      mood_current_state:     attr_of("Mood", :current_state),
      wake_report_phase:      attr_of("WakeReport", :phase),
    }
  end

  def emitted_events
    runtime.event_bus.map { |e| e[:name] }
  end

  def emitted?(name)
    emitted_events.include?(name.to_s)
  end

  # ---- Dispatch + dream pulse threading ----------------------------------

  def step(command, **attrs)
    value_attrs = attrs.transform_values { |v| Hecks::Behaviors::Value.from(v) }
                       .transform_keys(&:to_s)
    runtime.dispatch(command, value_attrs)
    snap = snapshot
    @transitions << { command: command, attrs: attrs, after: snap }
    snap
  end

  # Regular REM dream pulse. Pulls fixture content for (cycle, pulse) and
  # dispatches Consciousness.DreamPulse with the english impression.
  def dream_pulse(cycle:, pulse:)
    row = llm.dream_pulse(cycle: cycle, pulse: pulse)
    impression = row["text_en"]
    dream_images << { cycle: cycle, pulse: pulse, lucid: false, text: impression }
    clock.tick!
    step("DreamPulse", impression: impression)
  end

  # Lucid REM dream pulse. Pulls a lucid fixture row for (cycle, pulse)
  # and dispatches BOTH Consciousness.DreamPulse (count + summary) AND
  # LucidDream.ObserveDream (observation list + latest_narrative) so the
  # spec can assert dream content threaded through both aggregates.
  def lucid_pulse(cycle:, pulse:)
    row = llm.lucid_observation(cycle: cycle, pulse: pulse)
    impression = row["text_en"]
    dream_images << { cycle: cycle, pulse: pulse, lucid: true, text: impression }
    clock.tick!
    step("DreamPulse", impression: impression)
    step("ObserveDream", observation: impression)
  end

  # Drive the full 8-cycle sleep with fixture-threaded dream content.
  # No real-time waiting — every gate advances by direct dispatch ; every
  # dream pulse pulls content from the FixtureLlmAdapter.
  def run_full_night(sleep_at:, wake_at:)
    step("EnterSleep", sleep_at: sleep_at)

    1.upto(TOTAL_CYCLES - 1) do |cycle|
      step("AdvanceLightToRem")
      REGULAR_REM_PULSES.times do |i|
        dream_pulse(cycle: cycle, pulse: i + 1)
      end
      step("AdvanceRemToDeep")
      step("AdvanceDeepToLight")
    end

    # Cycle 8 — lucid path with 8 pulses + final light + wake.
    step("AdvanceLightToLucidRem")
    LUCID_REM_PULSES.times do |i|
      lucid_pulse(cycle: TOTAL_CYCLES, pulse: i + 1)
    end
    step("AdvanceRemToDeep")
    step("AdvanceDeepToFinalLight")
    step("CompleteFinalLight", wake_at: wake_at)
  end

  # The fixture's dream_interpretation lesson, fetched by total cycle
  # count. Used by the spec to verify the wake report's lesson is
  # threaded from the fixture rather than synthesized in the runtime.
  # (See gap note in the spec : composing the lesson into the
  # WakeReport aggregate is shell-side today.)
  def wake_lesson(cycle_total: TOTAL_CYCLES)
    llm.dream_interpretation(cycle_total: cycle_total)
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
      name:       "DreamStudyFullNight",
      aggregates: aggregates,
      policies:   policies,
    )
    rt = Hecks::Behaviors::BehaviorRuntime.boot(domain)
    domain.aggregates.each do |agg|
      rt.repositories[agg.name]["1"] = Hecks::Behaviors::AggregateState.new("1")
    end
    rt
  end
end

# TestClock — the fake cadence "adapter" for the in-memory runtime.
#
# BehaviorRuntime today has no real cadence surface ; this fake exists
# to give the spec a named seam ("the clock advances 43 times in a full
# night") and to assert that count without coupling to wall-clock time.
# When the production cadence adapter lands, this stub becomes a
# drop-in shape — same `tick!` API, same `ticks` accessor.
class TestClock
  attr_reader :ticks

  def initialize
    @ticks = 0
  end

  def tick!(by = 1)
    @ticks += by
    self
  end
end

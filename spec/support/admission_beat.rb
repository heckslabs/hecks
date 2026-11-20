# frozen_string_literal: true

require "hecks/hecks/adapters/waking"
require_relative "os_level_readings"

# The machine of 2026-11-20 03:24 for the beat under admission by headroom: two coders started
# against a cap of two, calm load, one planned coder, and the real Admitting over a door whose
# beat reads the given memory pressure level. A spec sets `machine[:level]` and `machine[:runs]`.
module AdmissionBeat
  include OsLevelReadings

  # The time the beat looks at.
  NOW = Time.utc(2026, 11, 20, 10, 24, 0)

  # @return [Hash] `level:` the OS's memory pressure level, `runs:` the agent runs by key
  def machine = @machine ||= { level: 1, runs: {} }

  # @param key [String] the work item's key
  # @return [Hecks::Adapters::Dispatching::Plan::Item] a lower-tier coder's work item
  def planned(key)
    Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key], priority: "next")
  end

  # @param seconds [Integer] how long ago the newest coder started
  # @return [Hash] the runs, the newest started that long ago
  def started_ago(seconds) = machine[:runs] = { "live-b" => { started_at: (NOW - seconds).iso8601 } }

  # @return [Hash] the stand-ins for the machine, the clock, the queue and Signalbox's admission
  def admission_settings
    { load: -> { 2.0 }, cpus: 10, cap: 2, work_items: beat_work_items, now: -> { NOW }, admitting: real_admitting,
      boots: Hecks::Adapters::BootBudget.new(entries: ->(_cutoff) { [] }, now: -> { NOW }),
      runner: ->(*) { raise "no launch" } }
  end

  # @param settings [Hash] the stand-ins the beat reads
  # @return [String] why the beat rolls, or the refusal's message
  def beat_with(settings)
    waking = Hecks::Adapters::Waking.new(registry: boot_hecks_in_memory.registry, settings: settings)
    waking.notice(run: { value: "beat-1" }).dig(:reason, :value)
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  private

  def real_admitting
    Hecks::Adapters::Dispatching::Admitting.new(runs: machine[:runs], now: NOW, door: door_at(machine[:level]))
  end

  def beat_work_items
    items = [planned("tiles")]
    instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: items, rollable: items, runs: machine[:runs],
                                                             lessons: [], started: [planned("live-a"), planned("live-b")])
  end
end

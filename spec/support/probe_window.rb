# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "machine_beats"
require "hecks/hecks/adapters/probe_measuring"

# Turns a setting through the Hecks domain in Memory and beats once after it, the pipeline's events
# logged in a scratch event log, and answers the turn's probe.
module ProbeWindow
  include MachineBeats

  TURNED_AT = Time.utc(2026, 11, 19, 19, 17).to_i

  # One calm machine reading, as the moving cap's spec beats it.
  CALM = { cpu_idle: 60.0, load: 3.0, swap_used: 1.0, swap_used_mb: 10.0, free_gb: 10.0, compressor_gb: 2.0,
           pressure_level: 1.0, lane_waiting: nil }.freeze

  # A Turning port that records what it restores, and answers as the real one does.
  FakeTurning = Struct.new(:restored) do
    def set(**) = { output: { value: "turned" }, before: { value: "false" }, after: { value: "true" } }

    def restore(**held) = (restored << held.slice(:setting, :before)) && { output: { value: "restored" } }
  end

  # The baseline: eight starts and four landings in the two hours before the turn.
  def baseline
    (1..8).map { |n| logged("WorkStarted", "w#{n}", TURNED_AT - (n * 600)) } +
      (1..4).map { |n| logged("BranchLanded", "b#{n}", TURNED_AT - (n * 900)) }
  end

  def logged(name, id, at) = { kind: "event", at: Time.at(at).utc.iso8601, aggregate: "Hecks::X", id: id, event: name }

  # @return [Hash, nil] the turn's probe once a beat `after` seconds past the turn has run
  def probed(window_events, after: 1801, probe: true)
    Dir.mktmpdir do |folder|
      log = File.join(folder, "events.jsonl")
      File.write(log, (baseline + window_events).map { |row| "#{JSON.generate(row)}\n" }.join)
      run_through(log, after, probe)
    end
  end

  def run_through(log, after, probe)
    MachineBeats::Sampling.last = nil
    registry = boot_hecks_in_memory.registry
    Hecks::Runtime::AdapterLookup.standing_in(ports(registry, log)) do
      clocked(TURNED_AT) { turn(registry, probe) }
      clocked(TURNED_AT + after) { beat(registry, 0) }
    end
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("Probe")).find("r1")
  end

  # @return [FakeTurning] the Turning port the turns of this example reach
  def turning = (@turning ||= FakeTurning.new([]))

  def ports(registry, log)
    measuring = Hecks::Adapters::ProbeMeasuring.new(registry: registry, settings: { tap: log, standing: ->(_) { "true" } })
    beats = wiring(registry, [CALM], [])
    held = { "Turning" => turning, "Measuring" => measuring }
    ->(port, asked) { held[port.to_s] || beats.call(port, asked) }
  end

  def clocked(now)
    allow(Hecks::Ports::Clock).to receive(:now).and_return(now)
    yield
  end

  def turn(registry, probe)
    Hecks::Runtime::Dispatcher.new(registry).dispatch_flat(
      "Hecks::Dial.Turn", run: { value: "r1" }, setting: { value: "admission.signalbox" }, becomes: { value: "on" },
                          probe: { value: probe }
    )
  end

  def status(probe) = probe && probe[:status]

  # @return [Integer] when the examples' turn is made, in epoch seconds
  def turned_at = TURNED_AT
end

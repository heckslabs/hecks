require "hecks/hecks/adapters/machine_sampling"

# Beats of a clock against the Delegate domain in Memory, with a fake machine behind the
# Sampling port and a rolling port that counts its fills.
module MachineBeats
  Sampling = Hecks::Adapters::MachineSampling

  # Boots the Hecks domain in Memory and beats once for each reading of a fake machine.
  #
  # @param series [Array<Hash>] the gauges of each beat: `cpu_idle`, `swap_used`, `load`, ...
  # @return [Hash] `names:` the events in order, `rolls:` the fills the rolling port answered
  def beat_through(series)
    Sampling.last = nil
    registry = boot_hecks_in_memory(File.expand_path("../../lib/hecks/hecks", __dir__)).registry
    rolls = []
    Hecks::Runtime::AdapterLookup.standing_in(wiring(registry, series.dup, rolls)) do
      series.each_index { |index| beat(registry, index) }
    end
    { names: registry.event_log.map(&:name), rolls: rolls }
  end

  def beat(registry, index)
    Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-#{index}" })
  end

  def wiring(registry, series, rolls)
    seconds = 0
    sampling = Sampling.new(registry: registry, settings: { readings: -> { series.shift }, clock: -> { seconds += 120 } })
    rolling = Struct.new(:rolls) { def roll(**) = (rolls << 1) && { report: { value: "fill #{rolls.size}" } } }.new(rolls)
    ->(port, _asked) { port.to_s == "Sampling" ? sampling : rolling }
  end

  def crossings(names) = names.grep(/\A(LoadFellBelow|LoadRoseAbove|MemoryLow|MemoryRecovered|TestLaneBusy|TestLaneIdle)\z/)

  def gauge(idle, swap = 10.0, lane = nil)
    { cpu_idle: idle, load: 9.0, swap_used: swap, compressor_gb: 2.0, lane_waiting: lane }
  end
end

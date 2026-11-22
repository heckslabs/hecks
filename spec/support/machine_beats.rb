require "hecks/hecks/adapters/machine_sampling"

# Beats of a clock against the Delegate domain in Memory, with a fake machine behind the
# Sampling port and a rolling port that counts its fills.
module MachineBeats
  Sampling = Hecks::Adapters::MachineSampling

  # Boots the Hecks domain in Memory and beats once for each reading of a fake machine.
  #
  # @param series [Array<Hash>] the gauges of each beat: `cpu_idle`, `swap_used_mb`, `load`, ...
  # @param niceness [Array<Integer>, nil] the count of niced Claude processes each beat finds
  # @return [Hash] `names:` the events in order, `rolls:` the fills the rolling port answered,
  #   `registry:` the booted registry the beats ran against
  def beat_through(series, niceness: nil)
    Sampling.last = nil
    registry = boot_hecks_in_memory(File.expand_path("../../lib/hecks/hecks", __dir__)).registry
    rolls = []
    Hecks::Runtime::AdapterLookup.standing_in(wiring(registry, series.dup, rolls, niceness&.dup)) do
      series.each_index { |index| beat(registry, index) }
    end
    { names: registry.event_log.map(&:name), rolls: rolls, registry: registry }
  end

  def beat(registry, index)
    Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-#{index}" })
  end

  def wiring(registry, series, rolls, counts = nil)
    seconds = 0
    settings = { readings: -> { series.shift }, clock: -> { seconds += 120 } }
    settings[:niceness] = -> { counts.shift.to_f } if counts
    sampling = Sampling.new(registry: registry, settings: settings)
    ->(port, _asked) { port.to_s == "Sampling" ? sampling : CountedRolls.new(rolls) }
  end

  # A rolling port whose owner's switch is on and whose fills are counted. Each read keys its
  # roll by the asking run and the reads so far, as the real port keys it by the time.
  CountedRolls = Struct.new(:rolls) do
    def read(run: nil, **)
      @reads = @reads.to_i + 1
      { state: "on", standing: 0, roll: { value: "#{run.is_a?(Hash) ? run[:value] : run}@#{@reads}" } }
    end

    def roll(**) = (rolls << 1) && { report: { value: "fill #{rolls.size}" } }
  end

  def crossings(names) = names.grep(/\A(LoadFellBelow|LoadRoseAbove|MemoryLow|MemoryRecovered|TestLaneBusy|TestLaneIdle)\z/)

  def gauge(idle, swap_mb = 10.0, lane = nil, free: 10.0)
    { cpu_idle: idle, load: 7.0, swap_used: 10.0, swap_used_mb: swap_mb, free_gb: free, compressor_gb: 2.0, lane_waiting: lane }
  end
end

require "hecks/hecks/adapters/machine_sampling"

# Gauges and the states they leave, for the specs of the machine's sampling.
module MachineReadings
  Sampling = Hecks::Adapters::MachineSampling

  def states(readings, before = {})
    Sampling::States.new(readings, Sampling::Marks::DEFAULTS, before).to_h
  end

  def gauges(idle: 60.0, load: 5.0, swap: 10.0, compressor: 2.0, lane: nil)
    { cpu_idle: idle, load: load, swap_used: swap, compressor_gb: compressor, lane_waiting: lane }
  end

  # The load state after each CPU idle percentage of a series, each reading made with the state
  # before and a load average inside its own gap, so the CPU alone decides.
  def loads(series)
    standing = {}
    series.map do |idle|
      standing = { load: states(gauges(idle: idle, load: 9.0), standing)[:load_state] }
      standing[:load]
    end
  end
end

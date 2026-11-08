# frozen_string_literal: true

module Hecks
  module Adapters
    class MachineSampling
      # The marks a reading is judged against: the Tickets world's `machine_marks` line laid over
      # these defaults. Each state has two marks with a gap between them, so a reading inside the
      # gap changes nothing and a gauge that hovers near one mark does not flap.
      class Marks
        # The world verb that carries the marks.
        VERB = "machine_marks"

        # The marks when the world says none.
        #
        # - `load_low`, `load_high`: the load average that tips the load when the CPU is not clear.
        # - `cpu_idle_low`: CPU idle percentage at or under which the load has risen.
        # - `cpu_idle_high`: CPU idle percentage at or over which the load has fallen.
        # - `swap_low`: swap used, as a percentage of swap total, over which memory is low.
        # - `swap_recovered`: swap used under which memory has recovered.
        # - `compressor_gb`: compressor size over which memory is low.
        # - `lane_busy`, `lane_idle`: test lane waiting count at or over, and at or under.
        # - `interval`: seconds between two readings.
        DEFAULTS = {
          load_low:       8.0,
          load_high:      10.0,
          cpu_idle_low:   25.0,
          cpu_idle_high:  40.0,
          swap_low:       70.0,
          swap_recovered: 50.0,
          compressor_gb:  12.0,
          lane_busy:      4.0,
          lane_idle:      1.0,
          interval:       60.0
        }.freeze

        # @param registry [Runtime::Registry, nil] the booted registry whose Tickets world is read
        # @return [Hash{Symbol => Float}] the marks, the world's laid over the defaults
        def self.of(registry)
          declared = registry&.world("Tickets")&.for_verb(VERB) || {}
          DEFAULTS.merge(declared.slice(*DEFAULTS.keys)) { |_key, _default, given| given.to_f }
        end
      end
    end
  end
end

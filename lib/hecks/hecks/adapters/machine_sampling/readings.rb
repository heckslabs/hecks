# frozen_string_literal: true

require_relative "../shell"
require_relative "../dispatching/settings"

module Hecks
  module Adapters
    class MachineSampling
      # The machine's own figures, read from `top`, `sysctl` and `uptime`. A figure the machine
      # does not give is nil, and a gauge that is nil changes no state. The memory-free percentage
      # is not read: it showed 40% free beside a full swap and a 17 gigabyte compressor.
      class Readings
        # `CPU usage: 28.7% user, 11.2% sys, 60.1% idle`.
        IDLE = /([0-9.]+)% idle/

        # `PhysMem: 35G used (2G wired, 17G compressor), 101M unused.`
        COMPRESSOR = /([0-9.]+)([MG]) compressor/

        # `total = 12288.00M  used = 10547.31M  free = 1740.69M`.
        SWAP = /total = ([0-9.]+)M\s+used = ([0-9.]+)M/

        # @param shell [#capture] runs a program and answers what it said; the {Shell} when nil
        def initialize(shell: nil)
          @shell = shell || Shell.new
        end

        # @return [Hash{Symbol => Float, nil}] the gauges: `cpu_idle`, `swap_used` (percent),
        #   `compressor_gb`, `load` and `lane_waiting` (nil until the test lane exists)
        def call
          top = said("top", "-l", "1", "-n", "0")
          { cpu_idle: idle(top), swap_used: swap(said("sysctl", "-n", "vm.swapusage")),
            compressor_gb: compressor(top), load: load, lane_waiting: nil }
        end

        # @param text [String] what `top` printed
        # @return [Float, nil] the CPU idle percentage
        def idle(text) = text[IDLE, 1]&.to_f

        # @param text [String] what `top` printed
        # @return [Float, nil] the compressor's size in gigabytes
        def compressor(text)
          match = COMPRESSOR.match(text)
          match && (match[2] == "G" ? match[1].to_f : match[1].to_f / 1024)
        end

        # @param text [String] what `sysctl -n vm.swapusage` printed
        # @return [Float, nil] swap used as a percentage of swap total; nil when there is no swap
        def swap(text)
          match = SWAP.match(text)
          match && match[1].to_f.positive? ? (match[2].to_f * 100 / match[1].to_f).round(1) : nil
        end

        private

        def said(*command) = @shell.capture(*command).out

        def load = Dispatching::Settings.uptime_load(said("uptime"))
      end
    end
  end
end

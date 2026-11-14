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

        # `Mach Virtual Memory Statistics: (page size of 16384 bytes)`, then `Pages free:  62321.`.
        PAGE_SIZE = /page size of (\d+) bytes/

        # @param shell [#capture] runs a program and answers what it said; the {Shell} when nil
        def initialize(shell: nil)
          @shell = shell || Shell.new
        end

        # @return [Hash{Symbol => Float, nil}] the gauges: `cpu_idle`, `swap_used` (percent),
        #   `compressor_gb`, `load` and `lane_waiting` (nil until the test lane exists)
        def call
          top = said("top", "-l", "1", "-n", "0")
          usage = said("sysctl", "-n", "vm.swapusage")
          { cpu_idle: idle(top), swap_used: swap(usage), swap_used_mb: swap_mb(usage),
            free_gb: free_gb(said("vm_stat")), compressor_gb: compressor(top), load: load, lane_waiting: nil }
        end

        # @param text [String] what `sysctl -n vm.swapusage` printed
        # @return [Float, nil] swap used in megabytes
        def swap_mb(text) = SWAP.match(text)&.then { |match| match[2].to_f.round(1) }

        # @param text [String] what `vm_stat` printed
        # @return [Float, nil] free plus inactive memory in gigabytes: what the machine can give
        #   a job now without swapping, which is the pressure swap's size cannot show
        def free_gb(text)
          size = text[PAGE_SIZE, 1]&.to_f
          pages = %w[free inactive].map { |kind| text[/^Pages #{kind}:\s+(\d+)/, 1]&.to_f }
          size && pages.none?(&:nil?) ? (pages.sum * size / (1024**3)).round(2) : nil
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

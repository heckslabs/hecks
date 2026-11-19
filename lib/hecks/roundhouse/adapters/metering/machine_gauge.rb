# frozen_string_literal: true

module Hecks
  module Adapters
    class Metering
      # The machine's memory and load from what `sysctl` and `vm_stat` print. It only parses the
      # readings it is handed: `memsize` in bytes, `perf_cores` (the performance cores), `loadavg`
      # as `{ 1m 5m 15m }` and the `vm_stat` text.
      class MachineGauge
        BYTES_PER_MB = 1024 * 1024

        # The `vm_stat` lines whose pages count as used: what apps hold, what the kernel wires and
        # what the compressor occupies.
        USED = ["Pages active", "Pages wired down", "Pages occupied by compressor"].freeze

        PAGE_SIZE = /page size of (\d+) bytes/
        PAGES = /\A(.+?):\s+(\d+)\.?\s*\z/
        NUMBER = /[\d.]+/

        # @param reads [Hash] `memsize:`, `perf_cores:`, `loadavg:` and `vm_stat:`
        def initialize(reads)
          @reads = reads
        end

        # @return [Integer] the machine's memory in MB
        def capacity_mb = (@reads[:memsize].to_i / BYTES_PER_MB)

        # @return [Integer] the memory in use in MB: active, wired and compressed pages
        def used_mb
          text = @reads[:vm_stat].to_s
          (USED.sum { |name| pages(text).fetch(name, 0) } * text[PAGE_SIZE, 1].to_f / BYTES_PER_MB).round
        end

        # @return [Integer] the 1-minute load in hundredths
        def load = (@reads[:loadavg].to_s[NUMBER].to_f * 100).round

        # @return [Integer] the performance cores the load is read against
        def cores = @reads[:perf_cores].to_i

        private

        # Each `vm_stat` line's page count, by the line's name.
        def pages(text)
          @pages ||= text.each_line.filter_map { |line| PAGES.match(line.strip) }.to_h { |match| [match[1], match[2].to_i] }
        end
      end
    end
  end
end

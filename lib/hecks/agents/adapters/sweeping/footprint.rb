# frozen_string_literal: true

module Hecks
  module Adapters
    class Sweeping
      # What the machine holds now: the spare daemon processes and their memory, the compressor and
      # the swap. It reads with `ps`, `vm_stat` and `sysctl` and changes nothing.
      class Footprint
        PAGE_SIZE = /page size of (\d+) bytes/
        COMPRESSED = /Pages occupied by compressor:\s+(\d+)/

        # @param shell [#capture] runs the readers
        # @param table [ProcessTable] the process table
        def initialize(shell:, table:)
          @shell = shell
          @table = table
        end

        # @return [String] one line: processes, their memory, the compressor and the swap in use
        def line
          spares = @table.spare_processes
          "spare processes #{spares.length} (#{spares.sum(&:rss_kb) / 1024} MB), " \
            "compressor #{compressor_mb} MB, swap #{swap}"
        end

        private

        def compressor_mb
          out = text("vm_stat")
          size = out[PAGE_SIZE, 1].to_i
          (out[COMPRESSED, 1].to_i * size) / (1024 * 1024)
        end

        def swap
          out = text("sysctl", "-n", "vm.swapusage")
          total, used = %w[total used].map { |word| out[/#{word} = ([\d.]+)M/, 1].to_f }
          total.zero? ? "unknown" : "#{used.round} of #{total.round} MB (#{(used * 100 / total).round}%)"
        end

        def text(*command)
          result = @shell.capture(*command)
          result.ok? ? result.out : ""
        end
      end
    end
  end
end

# frozen_string_literal: true

require "etc"
require "open3"

module Hecks
  module Adapters
    class MachineProfiling
      # Measures this machine: the facts a profile holds. It decides nothing; the rows derive from
      # them. Each fact comes from the OS (`sysctl`, `vm_stat`, `df`) and falls back to the figure
      # the standard library gives when the OS does not answer.
      class Reading
        # The size a resident or a coder is taken to be until one is measured (megabytes).
        UNMEASURED = { resident_mb: 400, coder_mb: 1_000 }.freeze

        # The page size line and the page counts `vm_stat` prints.
        PAGE_SIZE = /page size of (\d+)/
        FREE_PAGES = /Pages (?:free|inactive):\s+(\d+)/

        # @param run [#call] runs a command and answers its output, "" when it fails
        def initialize(run: method(:shell))
          @run = run
        end

        # @return [Hash{Symbol => Object}] the profile's measures and its fingerprint
        def facts
          perf = number("sysctl -n hw.perflevel0.physicalcpu", Etc.nprocessors)
          eff = number("sysctl -n hw.perflevel1.physicalcpu", 0)
          memory = number("sysctl -n hw.memsize", 0) / 1_048_576
          { performance_cores: perf, efficiency_cores: eff, cores: perf + eff, memory_mb: memory,
            free_memory_mb: free_memory(memory), free_disk_gb: free_disk,
            fingerprint: "p#{perf}-e#{eff}-#{memory}" }.merge(UNMEASURED)
        end

        private

        def free_memory(memory)
          pages = @run.call("vm_stat")
          size = pages[PAGE_SIZE, 1].to_i
          free = pages.scan(FREE_PAGES).flatten.sum(&:to_i)
          size.positive? ? free * size / 1_048_576 : memory / 2
        end

        def free_disk = @run.call("df -k .").lines.last.to_s.split[3].to_i / 1_048_576

        def number(command, fallback) = Integer(@run.call(command).strip, exception: false) || fallback

        def shell(command)
          Open3.capture2e(command).first
        rescue SystemCallError
          ""
        end
      end
    end
  end
end

# frozen_string_literal: true

require "open3"
require "hecks/ci_speed/adapters/local_runner/refused"

module Hecks
  module Adapters
    class LocalRunner
      # The machine's one-minute load average, which says how busy the machine was while an
      # experiment ran. Ruby's standard library does not report it, so it is read where the
      # system keeps it: `/proc/loadavg` where there is one, and what `uptime` prints elsewhere.
      module LoadAverage
        # The figure `uptime` prints after `load average:` or `load averages:`.
        UPTIME_FIGURE = /load averages?:\s*([0-9]+(?:[.,][0-9]+)?)/

        module_function

        # @return [Float] the one-minute load average
        # @raise [Refused] when the system reports none, since a result cannot be read without it
        def now
          return proc_figure if File.readable?("/proc/loadavg")

          out, status = Open3.capture2e("uptime")
          figure = out[UPTIME_FIGURE, 1] if status.success?
          raise Refused, "cannot read the load average: uptime printed #{out.strip.inspect}" unless figure

          figure.tr(",", ".").to_f
        end

        # @return [Float] the figure `/proc/loadavg` leads with
        def proc_figure
          words = File.read("/proc/loadavg").split
          words.first.to_f
        end
      end
    end
  end
end

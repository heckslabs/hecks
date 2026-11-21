# frozen_string_literal: true

require_relative "../shell"

module Hecks
  module Adapters
    class StallWatching
      # The machine's 1-minute load, read the way Roundhouse's meter reads it (`sysctl vm.loadavg`)
      # and from `/proc/loadavg` where there is no `sysctl`. A reading that cannot be made answers
      # nil, so the impediment view names the failure instead of stopping.
      class MachineLoad
        # Where Linux keeps the load averages.
        PROC = "/proc/loadavg"
        FIGURE = /\A\{?\s*(\d+(?:\.\d+)?)/

        # @param shell [#capture] runs `sysctl`; the {Shell} when nil
        # @param proc_path [String] the file of load averages read when `sysctl` answers nothing
        def initialize(shell: nil, proc_path: PROC)
          @shell = shell || Shell.new
          @proc_path = proc_path
        end

        # @return [Float, nil] the 1-minute load, nil when neither source answers a figure
        def call
          figure(sysctl) || figure(proc_file)
        end

        private

        def figure(text) = (found = FIGURE.match(text.to_s.strip)) && found[1].to_f

        def sysctl
          result = @shell.capture("sysctl", "-n", "vm.loadavg")
          result.ok? ? result.out : nil
        rescue SystemCallError
          nil
        end

        def proc_file
          File.readable?(@proc_path) ? File.read(@proc_path) : nil
        rescue SystemCallError
          nil
        end
      end
    end
  end
end

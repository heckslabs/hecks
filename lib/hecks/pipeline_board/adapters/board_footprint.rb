# frozen_string_literal: true

require_relative "probe"

module Hecks
  module Adapters
    module PipelineBoard
      # The memory macOS charges a process, read with `footprint`. On macOS the resident size `ps`
      # reports also counts the pages malloc has freed and the system has not yet taken back, so a
      # board that holds 550 megabytes can show 1400 there; the physical footprint is what it holds.
      module BoardFootprint
        PROGRAM = "/usr/bin/footprint"
        # The line `footprint -p` prints the physical footprint on, with its unit.
        LINE = /phys_footprint:\s+([\d.]+)\s*(B|KB|MB|GB)\b/
        # Megabytes in each unit.
        SCALE = { "B" => 1.0 / 1_048_576, "KB" => 1.0 / 1024, "MB" => 1.0, "GB" => 1024.0 }.freeze

        module_function

        # @return [Boolean] whether this machine can read a footprint
        def available? = File.executable?(PROGRAM)

        # @param pid [Integer] the process measured
        # @return [Float, nil] its physical footprint in megabytes, nil when none is printed
        # @raise [Unavailable] when `footprint` cannot answer
        def megabytes(pid) = parse(Probe.run(PROGRAM, "-p", pid.to_s))

        # @param text [String] what `footprint -p` printed
        # @return [Float, nil] the physical footprint in megabytes, nil when the text holds none
        def parse(text)
          found = LINE.match(text.to_s)
          found && (found[1].to_f * SCALE.fetch(found[2]))
        end
      end
    end
  end
end

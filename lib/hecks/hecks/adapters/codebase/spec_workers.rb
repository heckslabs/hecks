# frozen_string_literal: true

require "etc"
require "hecks/rust_build/world_rows"

module Hecks
  module Adapters
    module Codebase
      # How many workers a parallel spec run takes: the machine's cores, held to the Tickets
      # world's `spec_workers` cap, so one run leaves the rest of the machine to the others.
      module SpecWorkers
        # The Tickets world verb that carries the cap.
        VERB = "spec_workers"

        # The cap when the world names none: the number `tickets.world` sets.
        DEFAULT_MAX = 6

        module_function

        # @param root [String] the hecks checkout whose world sets the cap
        # @param cores [Integer] the cores the run may spread over; the machine's when absent
        # @return [Integer] the workers to start, at least one
        def count(root, cores: Etc.nprocessors) = cores.clamp(1, [max_of(root), 1].max)

        # @param root [String] a hecks checkout
        # @return [Integer] the cap its Tickets world's `spec_workers` line sets, else `DEFAULT_MAX`
        def max_of(root) = Integer(RustBuild::WorldRows.row(root, VERB)[:max] || DEFAULT_MAX)
      end
    end
  end
end

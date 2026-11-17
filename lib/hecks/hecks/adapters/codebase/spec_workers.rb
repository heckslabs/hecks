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

        # The variable the parallel gem reads for its worker count.
        WORKERS = "PARALLEL_PROCESSOR_COUNT"

        # The cap when the world names none: the number `tickets.world` sets.
        DEFAULT_MAX = 6

        module_function

        # @param root [String] the hecks checkout whose world sets the cap
        # @param cores [Integer] the cores the run may spread over; the machine's when absent
        # @return [Integer] the workers to start, at least one
        # @param base [#[]] the environment; a `PARALLEL_PROCESSOR_COUNT` in it, set by a parent
        #   that holds a place or caps a run, holds the count further
        def count(root, cores: Etc.nprocessors, base: ENV)
          cores.clamp(1, [[max_of(root), parent_count(base)].compact.min, 1].max)
        end

        # @param base [#[]] the environment
        # @return [Integer, nil] the worker count a parent set, nil when absent or not positive
        def parent_count(base)
          given = Integer(base[WORKERS].to_s, exception: false)
          given if given&.positive?
        end

        # @param root [String] a hecks checkout
        # @return [Integer] the cap its Tickets world's `spec_workers` line sets, else `DEFAULT_MAX`
        def max_of(root) = Integer(RustBuild::WorldRows.row(root, VERB)[:max] || DEFAULT_MAX)
      end
    end
  end
end

# frozen_string_literal: true

module Hecks
  module Runtime
    class Dispatcher
      # What a command would write and announce, listed without writing or announcing it. Runs the
      # in-memory pipeline `dry_run?` runs; the save and emit seams report to DryRunPlan.
      module Planning
        # Lists what a command would write and announce, without writing or announcing it.
        #
        # Runs the same in-memory pipeline as `dry_run?`, with the save and emit seams reporting
        # instead of acting, so every command gets its plan from one place.
        #
        # @param verb [String] the fully qualified aggregate command verb
        # @param args [Hash{Symbol => Object}] the facts as flat keywords
        # @return [Array<String>] one `would write` or `would emit` line per effect, in order
        # @raise [StandardError] any refusal the real dispatch would raise
        def plan_flat(verb, **args)
          DryRunPlan.collect { dry_run_call(flat_call(verb, args)) }
        end
      end
    end
  end
end

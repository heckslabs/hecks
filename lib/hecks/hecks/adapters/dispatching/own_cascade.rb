# frozen_string_literal: true

require "delegate"

module Hecks
  module Adapters
    class Dispatching
      # Runs a dispatch as the start of its own reaction cascade, and puts the caller's depth back
      # after, however the block ends. The depth lives in `Thread.current`, so a runtime
      # dispatched from inside another's reaction (Signalbox asked while a Work item's start
      # reacts) would otherwise inherit that depth, and its own chain would be cut off at the cap
      # before it reached its end.
      module OwnCascade
        # The thread-local the dispatcher counts a cascade's depth in.
        DEPTH = :hecks_reaction_depth

        # The depth a nested ask begins at: its own cascade, never capped by the caller's, and
        # below the outermost dispatch, which alone says a refused reaction on stderr. A refusal
        # inside an ask is its answer, not a note for the caller's output.
        NESTED = 1

        module_function

        # @param start [Integer] the depth the cascade begins at: nought, as a fresh process
        # @yieldreturn [Object] what the block answers
        # @return [Object] the block's value
        def run(start = 0)
          depth = Thread.current[DEPTH]
          Thread.current[DEPTH] = start
          yield
        ensure
          Thread.current[DEPTH] = depth
        end

        # A booted runtime whose dispatches and dry runs each begin their own cascade at
        # the nested depth; every other call reaches the runtime as it is.
        class Runtime < SimpleDelegator
          # @return [Runtime::Dispatcher::Result] the dispatch's result
          def dispatch(...) = OwnCascade.run(NESTED) { __getobj__.dispatch(...) }

          # @return [Boolean] what the dry run answers
          def dry_run?(...) = OwnCascade.run(NESTED) { __getobj__.dry_run?(...) }
        end
      end
    end
  end
end

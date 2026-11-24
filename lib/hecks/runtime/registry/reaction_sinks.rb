module Hecks
  module Runtime
    class Registry
      # The collections a dispatch opens on its own thread to read the reactions it caused: the
      # policy reactions the domain delivered or refused, and the asks a port adapter refused.
      module ReactionSinks
        # Records a port adapter's refusal of an ask on every collection open on this thread, so
        # the dispatch that caused the ask reports it beside its refused policy reactions. It is
        # not added to the shared reaction log, whose shape the Rust kernel also writes.
        #
        # @param record [Hash{Symbol => Object}] `{ policy:, trigger:, reason:, delivered: false,
        #   refuses: }`, the last naming the event the refusal announced
        # @return [void]
        def log_ask_refusal(record) = deliver_to_sinks(record)

        # Collects the reactions logged on this thread while the block runs, so one dispatch
        # reads exactly its own even when other threads dispatch on the same registry. Nested
        # dispatches (a reaction that dispatches) each collect, and the outer one sees theirs too.
        #
        # @yield [Array<Hash>] the collection, filled as reactions are logged
        # @return [Object] what the block returns
        def collecting_reactions
          sinks = (Thread.current[REACTION_SINKS] ||= [])
          sink  = []
          sinks << sink
          yield sink
        ensure
          sinks&.delete_if { |candidate| candidate.equal?(sink) }
        end

        private

        # Adds `record` to every collection open on this thread.
        def deliver_to_sinks(record)
          Array(Thread.current[REACTION_SINKS]).each { |sink| sink << record }
        end
      end
    end
  end
end

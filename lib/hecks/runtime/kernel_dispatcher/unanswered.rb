module Hecks
  module Runtime
    class KernelDispatcher
      # Raised for a part of the dispatcher surface the kernel's host protocol does not carry yet.
      class NotAnswered < StandardError; end

      # The parts of `Runtime::Dispatcher` the kernel's `--serve` answer does not carry yet: its
      # dispatch answer holds events only, not the reaction or saga records, and it takes no
      # query step. Each raises {NotAnswered} by name rather than answer an empty list.
      module Unanswered
        # @raise [NotAnswered] the kernel's answer carries no reaction records yet
        def reactions = unanswered("reactions", "its dispatch answer carries no reaction records")

        # @raise [NotAnswered] the kernel's answer carries no saga records yet
        def sagas = unanswered("sagas", "its dispatch answer carries no saga records")

        # @raise [NotAnswered] the kernel delivers reactions itself and keeps no outbox here
        def outbox = unanswered("outbox", "the kernel delivers reactions inside the dispatch")

        # @raise [NotAnswered] the kernel's `--serve` takes no query step yet
        def query(verb, **) = unanswered("query #{verb}", "--serve takes no query step")

        # @raise [NotAnswered] the kernel's `--serve` takes no query step yet
        def query_page(verb, **) = unanswered("query_page #{verb}", "--serve takes no query step")

        # @raise [NotAnswered] the kernel's `--serve` takes no plan step yet
        def plan_flat(verb, **) = unanswered("plan_flat #{verb}", "--serve takes no plan step")

        private

        def unanswered(what, why)
          raise NotAnswered, "the kernel engine does not answer #{what} yet: #{why}"
        end
      end
    end
  end
end

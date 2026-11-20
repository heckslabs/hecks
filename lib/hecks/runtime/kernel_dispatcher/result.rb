module Hecks
  module Runtime
    class KernelDispatcher
      # What one kernel dispatch settled on, in the shape `Dispatcher::Result` answers: the verb,
      # the events it announced, the identity its first event names, and the record that identity
      # holds in the kernel's store.
      #
      # The record is read only when a caller asks for `instance` or `state`, and the read is one
      # `instances` step answering the whole store, so it costs a round trip and grows with the
      # store until the protocol answers state with the dispatch.
      #
      # The kernel's dispatch answer carries no reaction records yet, so `refused_reactions`,
      # `blocking_reactions` and `reaction_defects` answer empty: a refused or crashed reaction
      # in the kernel is not reported through them.
      class Result
        # @return [String] the dispatched verb
        attr_reader :verb

        # @return [Array<Runtime::Event>] the events the dispatch announced
        attr_reader :events

        # @param verb [String] the dispatched verb
        # @param events [Array<Runtime::Event>] the events it announced
        # @param store [#call] answers the record for an aggregate name and identity, or nil
        def initialize(verb:, events:, store:)
          @verb = verb
          @events = events
          @store = store
        end

        # @return [String, nil] the identity the first announced event names
        def id = events.first&.id

        # @return [Runtime::Instance, nil] the record the kernel holds under that identity, read
        #   once
        def instance
          return @instance if defined?(@instance)

          first = events.first
          @instance = first && @store.call(first.aggregate, first.id)
        end

        # @return [Hash{Symbol => Object}, nil] the record's attributes with its `:id`; nil for none
        def state = instance&.to_h

        # @return [Array] empty: the kernel's answer carries no reaction records yet
        def refused_reactions = []

        # @return [Array] empty: the kernel's answer carries no reaction records yet
        def blocking_reactions = []

        # @return [Array] empty: the kernel's answer carries no reaction records yet
        def reaction_defects = []
      end
    end
  end
end

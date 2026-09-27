module Hecks
  module Bluebook
    module Behaviour
      # Readings over a process manager's trigger, states and handlers.
      # Its `saga` is derived from the handler that answers a refusal, not declared.
      module ProcessManager
        # The bluebook's name for this construct.
        #
        # @return [String, nil]
        def hecks_name = @name

        # The leg that answers an event from a state (C10.3, docs/semantics/bluebook-semantics.md).
        #
        # State, never declaration order, picks between legs; build refuses two legs on one
        # (event, state) pair. With no `state` the lookup is declarative: does any leg answer.
        #
        # @param event [String, Symbol]
        # @param state [String, Symbol, nil] the instance's current state; `nil` ignores state
        # @return [Bluebook::ProcessManagerHandler, nil]
        def handler_for(event, state = nil)
          @handlers.find { |h| h.event_type == event.to_s && (state.nil? || h.from_state == state.to_s) }
        end

        # Every declared leg for an event, regardless of source state.
        #
        # @param event [String, Symbol]
        # @return [Array<Bluebook::ProcessManagerHandler>]
        def handlers_for(event) = @handlers.select { |h| h.event_type == event.to_s }

        # Whether any declared leg answers an event.
        #
        # @param event [String, Symbol]
        # @return [Boolean]
        def handles?(event) = @handlers.any? { |h| h.event_type == event.to_s }

        # Whether a state is one this procedure declares. A rehydrated instance in an
        # undeclared state is corruption from the durable round-trip.
        #
        # @param state [String, Symbol]
        # @return [Boolean]
        def declares_state?(state) = @states.map(&:to_s).include?(state.to_s)

        # The payload field a triggering event's instances are correlated by.
        #
        # @return [Symbol] the part of `correlates_by` before the first `.`
        def correlation_head = @correlates_by.to_s.split(".").first.to_sym

        # The compensation half, read off the handler that answers `REFUSED`.
        #
        # @return [Bluebook::Saga, nil] `nil` when no handler answers a refusal, which is
        #   legitimate: a hiring pipeline cannot un-interview anybody
        def saga
          leg = handler_for(Bluebook::ProcessManager::REFUSED)
          return nil unless leg

          # A static preview in declaration order, not one instance's runtime history.
          # Derived `compensates` come first, then the leg's hand-written body, so a saga
          # can derive some compensation and hand-write the rest.
          derived = handlers.flat_map { |handler| handler.dispatches.filter_map(&:compensates) }
          Bluebook::Saga.new(trigger: Bluebook::ProcessManager::REFUSED, from_state: leg.from_state,
                             to_state: leg.to_state, compensations: derived + leg.dispatches)
        end

        # Whether this procedure declares a handler for `REFUSED`.
        #
        # @return [Boolean]
        def saga? = !saga.nil?
      end
    end
  end
end

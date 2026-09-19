module Hecks
  module Bluebook
    module Behaviour
      # **What a process manager does**. Its declared half is the trigger,
      # the states and the handlers; the compensation half — `saga` — is
      # derived from the handler that answers a refusal, not declared.
      module ProcessManager
        # The bluebook's name for this construct.
        #
        # @return [String, nil] the process manager's declared name, or `nil` before it
        #   is set
        def hecks_name = @name

        # The leg that answers — selected by (event, current state), C10.3
        # (docs/semantics/bluebook-semantics.md). Two legs may answer the
        # same event from different states; which one runs is decided by
        # the state the instance is in, never by declaration order. With
        # no `state` the reading is declarative — "does any leg answer this
        # event, and what is it" — for callers that ask about the
        # procedure rather than an instance (`saga`, the outbox's consumer
        # selection). Build refuses two legs on one (event, state) pair
        # (`ProcessManagerBuilder#validate!`), so a stated lookup is
        # unambiguous by construction.
        #
        # @param event [String, Symbol] the triggering event's name
        # @param state [String, Symbol, nil] the instance's current state; `nil` asks
        #   declaratively, ignoring state
        # @return [Bluebook::ProcessManagerHandler, nil] the matching handler row, or `nil`
        #   if no declared leg answers this (event, state) pair
        def handler_for(event, state = nil)
          @handlers.find { |h| h.event_type == event.to_s && (state.nil? || h.from_state == state.to_s) }
        end

        # Finds every declared leg for an event, regardless of source state.
        #
        # @param event [String, Symbol] the triggering event's name
        # @return [Array<Bluebook::ProcessManagerHandler>] every handler row declared for
        #   `event`; `[]` if none is declared
        def handlers_for(event) = @handlers.select { |h| h.event_type == event.to_s }

        # Says whether any declared leg answers an event.
        #
        # @param event [String, Symbol] the triggering event's name
        # @return [Boolean] whether any handler row is declared for `event`
        def handles?(event) = @handlers.any? { |h| h.event_type == event.to_s }

        # Whether a state is one this procedure declares — asked of a value
        # a real run left a saga instance holding (its live or rehydrated
        # state), the way `Lifecycle#states` is asked of an aggregate's
        # resting field. A rehydrated instance in a state no handler could
        # have reached is corruption the durable round-trip introduced.
        #
        # @param state [String, Symbol] the state to check
        # @return [Boolean] whether `state` is one of this procedure's declared states
        def declares_state?(state) = @states.map(&:to_s).include?(state.to_s)

        # Names the payload field a triggering event's instances are correlated by.
        #
        # @return [Symbol] the head of `correlates_by` — the part before the first `.`
        def correlation_head = @correlates_by.to_s.split(".").first.to_sym

        # The compensation half of a procedure, read off the handler that
        # answers `REFUSED`.
        #
        # nil for a procedure with no answer to a refusal, which is a legitimate
        # thing to be — a hiring pipeline cannot un-interview anybody.
        #
        # @return [Bluebook::Saga, nil] the derived saga, or `nil` if no handler answers
        #   `REFUSED`
        def saga
          leg = handler_for(Bluebook::ProcessManager::REFUSED)
          return nil unless leg

          # `compensations` — a static preview, declaration order, not
          # one instance's own runtime history (which legs a given
          # instance actually completed is per-instance state,
          # `SagaInterpreter`'s own `completed_compensations`, not a
          # fact `Saga` — a pure declaration reading — could ever hold).
          # Every `compensates` any handler's own dispatch declares,
          # forward declaration order, then whatever this leg's own
          # hand-written body still lists — coexistence, not replacement
          # (`ProcessManagerBuilder::HandlerBuilder#dispatch_impl`'s own
          # comment): a saga can derive some of its compensation and
          # still hand-write the rest for what isn't expressible as
          # "undo command X".
          derived = handlers.flat_map { |handler| handler.dispatches.filter_map(&:compensates) }
          Bluebook::Saga.new(trigger: Bluebook::ProcessManager::REFUSED, from_state: leg.from_state,
                             to_state: leg.to_state, compensations: derived + leg.dispatches)
        end

        # Says whether this procedure declares a handler for `REFUSED`.
        #
        # @return [Boolean] whether this procedure has a derivable saga
        def saga? = !saga.nil?
      end
    end
  end
end

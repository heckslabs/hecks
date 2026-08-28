module Hecks
  module Bluebook
    module Behaviour
      # WHAT A PROCESS MANAGER DOES. Its declared half is the trigger,
      # the states and the handlers; the compensation half — `saga` — is
      # DERIVED from the handler that answers a refusal, not declared.
      module ProcessManager
        def hecks_name = @name

        def handler_for(event) = @handlers.find { |h| h.event_type == event.to_s }

        # WHETHER A STATE IS ONE THIS PROCEDURE DECLARES — asked of a value
        # a real run left a saga instance holding (its live or rehydrated
        # state), the way `Lifecycle#states` is asked of an aggregate's
        # resting field. A rehydrated instance in a state no handler could
        # have reached is corruption the durable round-trip introduced.
        def declares_state?(state) = @states.map(&:to_s).include?(state.to_s)

        def correlation_head = @correlates_by.to_s.split(".").first.to_sym

        # The compensation half of a procedure, read off the handler that
        # answers REFUSED.
        #
        # nil for a procedure with no answer to a refusal, which is a legitimate
        # thing to be — a hiring pipeline cannot un-interview anybody.
        def saga
          leg = handler_for(Bluebook::ProcessManager::REFUSED)
          return nil unless leg

          # `compensations` — a STATIC PREVIEW, declaration order, not
          # one instance's own runtime history (which legs a given
          # instance actually completed is per-instance state,
          # `SagaInterpreter`'s own `completed_compensations`, not a
          # fact `Saga` — a pure declaration reading — could ever hold).
          # Every `compensates` ANY handler's own dispatch declares,
          # forward declaration order, THEN whatever this leg's own
          # hand-written body still lists — coexistence, not replacement
          # (`ProcessManagerBuilder::HandlerBuilder#dispatch_impl`'s own
          # comment): a saga can derive some of its compensation and
          # still hand-write the rest for what isn't expressible as
          # "undo command X".
          derived = handlers.flat_map { |handler| handler.dispatches.filter_map(&:compensates) }
          Bluebook::Saga.new(trigger: Bluebook::ProcessManager::REFUSED, from_state: leg.from_state,
                             to_state: leg.to_state, compensations: derived + leg.dispatches)
        end

        def saga? = !saga.nil?
      end
    end
  end
end

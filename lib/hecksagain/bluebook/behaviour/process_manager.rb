module Hecksagain
  class Bluebook
    module Behaviour
      # WHAT A PROCESS MANAGER DOES. Its declared half is the trigger,
      # the states and the handlers; the compensation half — `saga` — is
      # DERIVED from the handler that answers a refusal, not declared.
      module ProcessManager
        def hecks_name = @name

        def handler_for(event) = @handlers.find { |h| h.event_type == event.to_s }

        def correlation_head = @correlates_by.to_s.split(".").first.to_sym

        # The compensation half of a procedure, read off the handler that
        # answers REFUSED.
        #
        # nil for a procedure with no answer to a refusal, which is a legitimate
        # thing to be — a hiring pipeline cannot un-interview anybody.
        def saga
          leg = handler_for(Bluebook::ProcessManager::REFUSED)
          return nil unless leg

          Bluebook::Saga.new(trigger: Bluebook::ProcessManager::REFUSED, from_state: leg.from_state,
                             to_state: leg.to_state, reversals: leg.dispatches)
        end

        def saga? = !saga.nil?
      end
    end
  end
end

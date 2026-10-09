require_relative "../../bluebook/ask_resolution"

module Hecks
  module Runtime
    class Registry
      # The boot gate for `ask`: every policy's ask must resolve to one declared port operation,
      # so a name the hecksagon never declared stops the boot instead of firing at nothing.
      # Mixed into {Verification}.
      module AskVerification
        private

        # A port operation a chapter provides, and an ask a policy makes, each name a port
        # operation the hecksagon declared.
        def refuse_unresolved_ports!
          refuse_unresolved_port_operations!
          refuse_unresolved_asks!
        end

        # Binds each ask to the operation it resolves to, refusing the first that resolves to none.
        #
        # @raise [WiringError] naming the policy, the ask and what the hecksagon would need
        def refuse_unresolved_asks!
          @declared.bluebooks.each_value do |chapter|
            chapter.policies.select(&:asks?).each do |policy|
              outcome = Bluebook::AskResolution.call(chapter, policy)
              raise WiringError, outcome.detail unless outcome.resolved?

              policy.resolve_ask!(outcome.verb)
            end
          end
        end
      end
    end
  end
end

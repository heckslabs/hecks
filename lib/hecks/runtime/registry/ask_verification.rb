require_relative "../../bluebook/ask_resolution"

module Hecks
  module Runtime
    class Registry
      # The boot gate for `ask`: every policy's ask must resolve to one declared port operation,
      # so a name the hecksagon never declared stops the boot instead of firing at nothing.
      # Mixed into {Verification}.
      module AskVerification
        private

        # A port operation a bluebook provides, and an ask a policy makes, each name a port
        # operation the hecksagon declared.
        def refuse_unresolved_ports!
          refuse_unresolved_port_operations!
          refuse_unresolved_asks!
        end

        # Binds each ask to the operation it resolves to, refusing the first that resolves to none.
        #
        # @raise [WiringError] naming the policy, the ask and what the hecksagon would need
        def refuse_unresolved_asks!
          @declared.bluebooks.each_value do |declaration|
            next if awaiting_sibling?(declaration)

            declaration.policies.select(&:asks?).each do |policy|
              outcome = Bluebook::AskResolution.call(declaration, policy)
              raise WiringError, outcome.detail unless outcome.resolved?

              policy.resolve_ask!(outcome.verb)
            end
          end
        end

        # A bounded context whose sibling hecksagon was never declared. Its asks have nowhere to
        # resolve, and the missing sibling is the refusal that names the cause.
        #
        # @param declaration [Bluebook] a loaded bluebook
        # @return [Boolean]
        def awaiting_sibling?(declaration)
          bounded?(declaration.hecks_name) && hecksagon(declaration.hecks_name).nil?
        end
      end
    end
  end
end

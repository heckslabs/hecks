require_relative "../caller"

module Hecks
  module Runtime
    class PortOperationInterpreter
      # Tells the dispatch that caused an ask that the port's adapter refused it, for a domain whose
      # world's `launcher` setting says `refused_asks: true`. A domain that does not say so keeps
      # its asks' refusals to their `refuses` events: many a no is a deliberate answer.
      module RefusalNote
        private

        # An ask a policy raised is reported to its dispatch as a refused reaction; an ask
        # dispatched directly is answered by its `refuses` event alone, since a healthy no is an
        # answer.
        def note_refusal(ctx, out, text)
          return unless Caller.reacting? && reported?(ctx.domain)

          verb = "#{ctx.domain}::#{ctx.aggregate_hecks_name}.#{port_name_for(ctx)}.#{ctx.operation_hecks_name}"
          @registry.log_ask_refusal(policy: ctx.operation_hecks_name, trigger: verb, reason: text,
                                    delivered: false, refuses: out.refuses)
        end

        # Whether the domain's world opts in to having its asks' refusals reported.
        def reported?(domain)
          declared = @registry.world(domain)&.for_verb("launcher")
          [true, "true"].include?(declared && declared[:refused_asks])
        end
      end
    end
  end
end

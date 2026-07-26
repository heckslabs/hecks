# Policy — an event arrives, a command fires.
#
# The domain's reflex. A command announces something happened ; a policy is the
# standing instruction that something else should follow. Without it the caller
# has to know every consequence of what it asked for, and the domain's causality
# lives in whoever happened to dispatch.
#
#   policy "ChargeOnPlacement" do
#     on      "OrderPlaced"
#     trigger "Payment.Charge"
#   end
#
# `across` names another domain when the reaction leaves this one — the reaction
# is still declared HERE, because this domain is the one that knows the event
# means something.
#
# The event name may be qualified : `on "Order.Placed"` fires only for that
# aggregate's event, while the bare `on "Placed"` matches the name wherever it
# is emitted.
module Hecksagain
  module Bluebook
    module IR
      class Policy
        attr_reader :name, :on_event, :trigger_command, :target_domain

        def initialize(name:, on_event: nil, trigger_command: nil, target_domain: nil)
          @name            = name.to_s
          @on_event        = on_event
          @trigger_command = trigger_command
          @target_domain   = target_domain
        end

        # The aggregate a qualified subscription names, or nil when bare.
        def event_qualifier
          aggregate, _event = @on_event.to_s.split(".", 2)
          @on_event.to_s.include?(".") ? aggregate : nil
        end

        # The event name with any `Aggregate.` qualifier stripped, which is what
        # the emitted-event set carries.
        def event_name
          @on_event.to_s.split(".", 2).last
        end

        def to_h
          {
            name:            @name,
            on_event:        @on_event,
            trigger_command: @trigger_command,
            target_domain:   @target_domain
          }
        end
      end
    end
  end
end

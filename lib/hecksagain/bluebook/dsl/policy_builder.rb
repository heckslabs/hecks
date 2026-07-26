# PolicyBuilder — evaluates a `policy "ChargeOnPlacement" do ... end` block.
#
# Brought over from Hecks's DSL::PolicyBuilder, narrowed to the three keywords
# the interpreter reads : `on`, `trigger`, `across`.
#
#   policy "ChargeOnPlacement" do
#     on      "OrderPlaced"
#     trigger "Payment.Charge"
#     across  "Payment"       # only when the reaction leaves this domain
#   end
#
# Hecks's builder also accepts `with`, `map`, `defaults`, `translate`,
# `condition` and `async`. Those are NOT brought over. Several are already inert
# there (`with` and `cross_domain` take their args and discard them), and the
# rest describe a reaction shape this interpreter cannot execute — a keyword
# that parses and then does nothing is worse than one that is absent, because
# absence is a syntax error and inertness is a silent no-op.
module Hecksagain
  module Bluebook
    module DSL
      class PolicyBuilder
        def initialize(name)
          @name = name
        end

        # The event this policy waits for. Bare (`"Placed"`) matches the name
        # anywhere ; qualified (`"Order.Placed"`) matches only that aggregate's.
        def on(event_name) = @on_event = event_name.to_s

        # The command that fires when it arrives.
        def trigger(command_name) = @trigger_command = command_name.to_s

        # The domain that command belongs to, when it is not this one.
        def across(domain_name) = @target_domain = domain_name.to_s

        def build
          IR::Policy.new(
            name:            @name,
            on_event:        @on_event,
            trigger_command: @trigger_command,
            target_domain:   @target_domain
          )
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end

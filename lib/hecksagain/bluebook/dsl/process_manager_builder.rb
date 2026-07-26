# ProcessManagerBuilder — evaluates a `process_manager "Checkout" do ... end`
# block.
#
# Brought over from Hecks's DSL::ProcessManagerBuilder — same keywords
# (`correlates_by`, `starts_on`, `ends_on`, `state`, `on ... transition:`) and
# the same nested handler surface (`dispatch`, `set`).
#
# ITS VALIDATIONS COME WITH IT, and they are the reason this builder is worth
# bringing rather than writing. A process manager that declares no states, or
# transitions to a state it never declared, or correlates by nothing, is not a
# slightly-wrong process manager — it is one that will wait forever for an event
# it can never match. Hecks learned each of those the hard way ; they are
# enforced at BUILD time here, so the bluebook refuses to load rather than
# running as a machine that silently never advances.
#
#   process_manager "Checkout" do
#     correlates_by :order_id
#     starts_on "OrderPlaced"
#     state "awaiting_payment"
#     state "paid"
#     on "PaymentAuthorized", transition: { "awaiting_payment" => "paid" } do
#       dispatch "Order.Confirm", with: { order: :order_id }
#     end
#   end
module Hecksagain
  module Bluebook
    module DSL
      class ProcessManagerBuilder
        class InvalidProcessManager < StandardError; end

        def initialize(name)
          @name     = name
          @states   = []
          @handlers = []
        end

        def correlates_by(field) = @correlates_by = field.to_sym
        def starts_on(event)     = @starts_on = event.to_s
        def ends_on(event)       = @ends_on = event.to_s
        def state(name)          = @states << name.to_s

        # One reaction. `transition:` is single-entry — one from, one to.
        def on(event_type, transition:, &block)
          from, to = single_transition(event_type, transition)
          handler  = HandlerBuilder.new
          handler.instance_eval(&block) if block

          @handlers << IR::ProcessManagerHandler.new(
            event_type: event_type.to_s,
            from_state: from,
            to_state:   to,
            dispatches: handler.dispatches
          )
        end

        def build
          validate!

          IR::ProcessManager.new(
            name:          @name,
            correlates_by: @correlates_by,
            starts_on:     @starts_on,
            ends_on:       @ends_on,
            states:        @states,
            handlers:      @handlers
          )
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        def single_transition(event_type, transition)
          unless transition.is_a?(Hash) && transition.size == 1
            raise InvalidProcessManager,
                  "#{@name}.on(#{event_type.inspect}) needs exactly one " \
                  "from => to transition, got #{transition.inspect}"
          end

          from, to = transition.first
          [from.to_s, to.to_s]
        end

        # Every rule here describes a machine that would LOAD and then never
        # advance. Refusing at build time is the whole point.
        def validate!
          raise InvalidProcessManager, "#{@name} declares no correlates_by — " \
            "nothing would tie its events to one instance" unless @correlates_by

          raise InvalidProcessManager, "#{@name} declares no starts_on — " \
            "nothing would ever begin it" if @starts_on.to_s.empty?

          raise InvalidProcessManager, "#{@name} declares no states" if @states.empty?

          raise InvalidProcessManager, "#{@name} declares no handlers — " \
            "it would start and then ignore every event" if @handlers.empty?

          undeclared = @handlers.flat_map { |h| [h.from_state, h.to_state] }
                                .uniq
                                .reject { |s| @states.include?(s) }
          return if undeclared.empty?

          raise InvalidProcessManager,
                "#{@name} transitions through #{undeclared.map(&:inspect).join(', ')} " \
                "which #{undeclared.size == 1 ? 'is' : 'are'} never declared as a state"
        end

        # The body of an `on ... do ... end` block.
        class HandlerBuilder
          attr_reader :dispatches

          def initialize = @dispatches = []

          # `with:` carries literal values and :symbol references, in
          # DECLARATION ORDER — a hash would lose it, and order is part of the
          # canonical shape.
          def dispatch(command_name, with: nil)
            @dispatches << IR::DispatchSpec.new(
              command_name: command_name,
              with_spec:    (with || {}).to_a
            )
          end
        end
      end
    end
  end
end

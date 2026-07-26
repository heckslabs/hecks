# ProcessManager — a conversation that outlives any one command.
#
# A policy is a reflex : one event, one command, no memory. A process manager
# REMEMBERS — it starts on an event, correlates every later event to the same
# instance by a shared field, moves through declared states, and ends. It is how
# a domain expresses "this takes several steps and can be half-done" without
# smuggling that fact into an aggregate that has no business knowing it.
#
#   process_manager "Checkout" do
#     correlates_by :order_id
#     starts_on "OrderPlaced"
#     ends_on   "OrderCompleted"
#
#     state "awaiting_payment"
#     state "paid"
#
#     on "PaymentAuthorized", transition: { "awaiting_payment" => "paid" } do
#       dispatch "Order.Confirm"
#     end
#   end
#
# A handler's transition is SINGLE-ENTRY — one from, one to — so the pair is
# carried as two named fields rather than a one-key map, and the canonical shape
# is unambiguous.
module Hecksagain
  module Bluebook
    module IR
      # One `dispatch "Cmd", with: { ... }` inside a handler.
      #
      # `with` is an ORDERED list of pairs, never a map : declaration order is
      # part of the canonical shape, and a hash would let two runtimes agree on
      # content while disagreeing on bytes.
      DispatchSpec = Struct.new(:command_name, :with_spec, keyword_init: true) do
        def to_h
          {
            command_name: command_name.to_s,
            with:         with_spec.map { |key, value| [key.to_s, IR.render_value(value)] }
          }
        end
      end

      ProcessManagerHandler = Struct.new(:event_type, :from_state, :to_state,
                                         :dispatches, keyword_init: true) do
        def to_h
          {
            event_type: event_type.to_s,
            from_state: from_state.to_s,
            to_state:   to_state.to_s,
            dispatches: dispatches.map(&:to_h)
          }
        end
      end

      class ProcessManager
        attr_reader :name, :correlates_by, :starts_on, :ends_on, :states, :handlers

        def initialize(name:, correlates_by: nil, starts_on: nil, ends_on: nil,
                       states: [], handlers: [])
          @name          = name.to_s
          @correlates_by = correlates_by
          @starts_on     = starts_on
          @ends_on       = ends_on
          @states        = states
          @handlers      = handlers
        end

        def handler_for(event) = @handlers.find { |h| h.event_type == event.to_s }

        def to_h
          {
            name:          @name,
            correlates_by: @correlates_by.to_s,
            starts_on:     @starts_on,
            ends_on:       @ends_on,
            states:        @states,
            handlers:      @handlers.map(&:to_h)
          }
        end
      end
    end
  end
end

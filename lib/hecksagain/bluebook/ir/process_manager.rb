module Hecksagain
  module Bluebook
    module IR
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
        # The trigger of a compensating leg. Not an event name — no aggregate
        # announces that a leg the procedure dispatched was declined — so it lives
        # here beside the thing it triggers rather than in the runtime that
        # notices it. Declared in the language's Trigger vocabulary, which
        # spec/vocabulary_conformance_spec holds to this constant.
        REFUSED = "refused".freeze

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

        # A PROCEDURE coordinates: legs, states, who goes next. It is a SAGA when
        # it also knows how to undo itself.
        #
        # The two are different things and the industry slurs them together. A
        # hiring pipeline is a procedure with no saga in it — you cannot
        # un-interview somebody. A choreographed refund is a saga with no
        # procedure — each party knows its own undo and nobody is in charge.
        # Banking's settlement is both.
        #
        # NAMED here and nowhere an author can type it. `saga` is not a word a
        # bank says, so it never appears in a .bluebook — the author declares a
        # compensating leg and the saga-ness follows. Derived, so it cannot drift
        # from the thing it describes, and deliberately NOT in to_h : the IR is a
        # shared contract with the Rust parser, and a derived fact is not a fact
        # about the source.
        def saga? = @handlers.any? { |handler| handler.event_type == REFUSED }

        # What it does when a leg is refused — nil for a procedure that has no
        # answer to that, which is a legitimate thing to be.
        def compensation = handler_for(REFUSED)

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

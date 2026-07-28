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

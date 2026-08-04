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

        def validate!
          raise InvalidProcessManager, "#{@name} declares no correlates_by — " \
            "nothing would tie its events to one instance" unless @correlates_by

          # THE FIELD, NAMED — never the value object that carries it. A bare
          # `correlates_by :end_to_end` reads whatever the payload holds under
          # that key AS the correlation key, and what a non-scalar key even
          # is stays open (the object itself? its serialised text?).
          # Requiring the dotted spelling —
          # `:"end_to_end.value"` — makes every correlates_by name a scalar
          # by construction, the same discipline `identified_by` already
          # holds a head to. This is a syntactic check, not a type check: it
          # does not know or care whether the field IS a value object, only
          # that the declaration cannot leave that question open.
          raise InvalidProcessManager, "#{@name} correlates_by #{@correlates_by.inspect}, which names a whole " \
            "field rather than one of its scalars — say which one, e.g. " \
            "#{@correlates_by}.value" unless @correlates_by.to_s.include?(".")

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

        class HandlerBuilder
          attr_reader :dispatches

          def initialize = @dispatches = []

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

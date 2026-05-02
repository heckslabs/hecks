module Hecks
  module DSL

    # Hecks::DSL::ProcessManagerBuilder
    #
    # DSL builder for the +process_manager+ keyword. Collects correlation key,
    # lifecycle events (+starts_on+/+ends_on+), explicit state declarations, and
    # +on "EventName", transition: { from: :to }+ handler blocks, then builds a
    # +BluebookModel::Behavior::ProcessManager+ IR node.
    #
    # Mirrors the runtime class +Hecks::EventSourcing::ProcessManager+ exactly,
    # so the DSL reads as a thin declarative wrapper around the runtime
    # primitive that already exists.
    #
    # Phase 1 of the dream-study plan: this lands the parser + IR only.
    # Runtime instantiation (subscribing to the event bus, walking declared
    # PMs at boot) is Phase 2 ; Rust parser is Phase 3.
    #
    #   process_manager "SleepCycle" do
    #     correlates_by :body_id
    #     starts_on    "SleepStarted"
    #     ends_on      "WakeFinished"
    #     state "light"
    #     state "rem"
    #     state "deep"
    #     state "studying_dream"
    #
    #     on "PhaseElapsed", transition: { light: :light } do |event, pm|
    #       { commands: ["AdvancePhase"] }
    #     end
    #
    #     on "DreamPulsed", transition: { rem: :rem } do |event, pm|
    #       { commands: ["RecordDream"] }
    #     end
    #   end
    #
    # Validation (raised as +ArgumentError+ at +build+ time):
    #
    # 1. every state mentioned in any transition must be declared via +state+
    # 2. +correlates_by+ must be a Symbol
    # 3. +starts_on+ and +ends_on+ must be Strings (event type names)
    # 4. at least one state must be declared
    # 5. at least one +on+ handler must be declared
    class ProcessManagerBuilder
      Behavior = BluebookModel::Behavior

      include Describable

      # Initialize a new ProcessManager builder.
      #
      # @param name [String] the PM name (PascalCase, e.g. "SleepCycle")
      def initialize(name)
        @name = name
        @correlates_by = nil
        @starts_on = nil
        @ends_on = nil
        @states = []
        @handlers = []
      end

      # Declare which event attribute correlates events to one PM instance.
      #
      # @param field [Symbol] the correlation attribute (e.g. :body_id)
      # @return [void]
      def correlates_by(field)
        @correlates_by = field
      end

      # Declare the event type that creates a new PM instance.
      #
      # @param event_type [String] the event type name
      # @return [void]
      def starts_on(event_type)
        @starts_on = event_type
      end

      # Declare the event type that archives a PM instance.
      #
      # @param event_type [String] the event type name
      # @return [void]
      def ends_on(event_type)
        @ends_on = event_type
      end

      # Declare a valid state for this PM. States are explicit; the builder
      # never infers states from transition keys.
      #
      # @param name [String, Symbol] the state name
      # @return [void]
      def state(name)
        @states << name.to_s
      end

      # Register a transition handler for an event type.
      #
      # The +transition+ hash MUST contain exactly one entry mapping the
      # +from+ state to the +to+ state. Both must be declared via +state+.
      # The optional block mirrors the runtime PM action signature
      # +|event, pm_instance|+ and typically returns +{ commands: [...] }+.
      #
      # @param event_type [String] the event name to handle
      # @param transition [Hash{Symbol,nil => Symbol}] from_state => to_state
      # @yield [event, pm] optional action block (captured but not executed)
      # @return [void]
      def on(event_type, transition:, &block)
        unless transition.is_a?(Hash) && transition.size == 1
          raise ArgumentError,
                "process_manager '#{@name}' on '#{event_type}' transition: " \
                "must be a single-entry { from: :to } hash, got #{transition.inspect}"
        end

        # Two block forms supported :
        #
        # 1. |event, pm| arity-2 — Ruby action proc returning
        #    { commands: [...] }. Opaque to Rust ; runs in Ruby PM only.
        # 2. arity-0 (no params) — declarative DSL. Block instance_evals
        #    against an OnHandlerBuilder that captures `dispatch "Cmd"`
        #    lines. The Rust runtime reads the dispatches list and fires
        #    commands ; no Ruby proc execution required.
        action = nil
        dispatches = []
        if block
          if block.arity == 2 || block.arity == -3
            action = block
          else
            sub = OnHandlerBuilder.new
            sub.instance_eval(&block)
            dispatches = sub.dispatches
          end
        end

        @handlers << Behavior::ProcessManager::Handler.new(
          event_type: event_type.to_s,
          transition: transition,
          action: action,
          dispatches: dispatches
        )
      end

      # Sub-builder for the declarative `dispatch "Cmd"` form inside
      # `on/transition do ... end`. Captures one or more dispatch lines
      # in declaration order. The parent reads `dispatches` after
      # instance_eval returns.
      class OnHandlerBuilder
        attr_reader :dispatches

        def initialize
          @dispatches = []
        end

        # Declare a command to dispatch when this handler fires.
        # Format : "AggregateName.CommandName" (qualified). Multiple
        # dispatches per handler fire in declaration order.
        def dispatch(command_name)
          @dispatches << command_name.to_s
        end
      end

      # Build and return the BluebookModel::Behavior::ProcessManager IR node.
      #
      # @return [BluebookModel::Behavior::ProcessManager]
      # @raise [ArgumentError] when validation rules fail
      def build
        validate!
        Behavior::ProcessManager.new(
          name: @name,
          correlates_by: @correlates_by,
          starts_on: @starts_on,
          ends_on: @ends_on,
          states: @states,
          handlers: @handlers,
          description: @description
        )
      end

      private

      def validate!
        validate_correlates_by!
        validate_event_type!(:starts_on, @starts_on, required: true)
        validate_event_type!(:ends_on, @ends_on, required: false)
        validate_states_present!
        validate_handlers_present!
        validate_transition_states_declared!
      end

      def validate_correlates_by!
        return if @correlates_by.is_a?(Symbol)
        raise ArgumentError,
              "process_manager '#{@name}' correlates_by must be a Symbol, " \
              "got #{@correlates_by.inspect}"
      end

      def validate_event_type!(label, value, required:)
        if value.nil?
          return unless required
          raise ArgumentError,
                "process_manager '#{@name}' missing required #{label} event type"
        end
        return if value.is_a?(String)
        raise ArgumentError,
              "process_manager '#{@name}' #{label} must be a String " \
              "(event type name), got #{value.inspect}"
      end

      def validate_states_present!
        return unless @states.empty?
        raise ArgumentError,
              "process_manager '#{@name}' must declare at least one state"
      end

      def validate_handlers_present!
        return unless @handlers.empty?
        raise ArgumentError,
              "process_manager '#{@name}' must declare at least one on-handler"
      end

      def validate_transition_states_declared!
        @handlers.each do |h|
          from, to = h.transition.first
          undeclared = [from, to].reject { |s| @states.include?(s.to_s) }
          next if undeclared.empty?
          raise ArgumentError,
                "process_manager '#{@name}' on '#{h.event_type}' references " \
                "undeclared state(s): #{undeclared.map(&:to_s).join(', ')} " \
                "(declared: #{@states.join(', ')})"
        end
      end
    end
  end
end

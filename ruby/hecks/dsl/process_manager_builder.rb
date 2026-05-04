# [antibody-exempt: ruby/hecks/dsl/process_manager_builder.rb — kernel-floor
#  PM DSL builder, Phase 2.c set-directive surface mirrors rust/src/parse_blocks.rs.]
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
        set_specs = []
        if block
          if block.arity == 2 || block.arity == -3
            action = block
          else
            sub = OnHandlerBuilder.new
            sub.instance_eval(&block)
            dispatches = sub.dispatches
            set_specs  = sub.set_specs
          end
        end

        @handlers << Behavior::ProcessManager::Handler.new(
          event_type: event_type.to_s,
          transition: transition,
          action: action,
          dispatches: dispatches,
          set_specs: set_specs
        )
      end

      # Sub-builder for the declarative `dispatch "Cmd"` form inside
      # `on/transition do ... end`. Captures one or more dispatch lines
      # in declaration order. The parent reads `dispatches` after
      # instance_eval returns.
      #
      # Two surface forms supported (Phase 2.b — pm-dispatch-enrichment) :
      #
      #   1. Bare command   :  +dispatch "Aggregate.Command"+
      #      No attribute flow. Runtime injects upstream refs only.
      #
      #   2. Enriched form  :  +dispatch "Aggregate.Command", with: { ... }+
      #      The +with:+ hash maps the receiving command's attribute name
      #      to a value spec. Three spec forms :
      #
      #        - String / scalar literal           — passed through as-is
      #        - +from_event(:name, default: ...)+ — reads event.data[name]
      #        - +from_pm(:name, default: ...)+    — reads pm.data[name]
      #
      # Sentinel methods +from_event+ and +from_pm+ return +ValueSpec+
      # objects that serialise into canonical IR ; the Rust runtime
      # evaluates them at dispatch time.
      class OnHandlerBuilder
        DispatchSpec = Behavior::ProcessManager::DispatchSpec
        ForEachSpec  = Behavior::ProcessManager::ForEachSpec
        ValueSpec    = Behavior::ProcessManager::ValueSpec

        attr_reader :dispatches, :set_specs

        def initialize
          @dispatches = []
          @set_specs  = []
        end

        # Declare a command to dispatch when this handler fires.
        # Format : "AggregateName.CommandName" (qualified). Multiple
        # dispatches per handler fire in declaration order.
        #
        # i221-A — +for_each:+ promotes a single dispatch to a sweep :
        # the runtime reads the named query at dispatch time and fires
        # the receiving command once per returned record. The +with:+
        # hash can mix the existing +literal+ / +from_event+ / +from_pm+
        # forms with the new +from_iter(:field)+ sentinel that reads
        # the current iteration record's attribute.
        #
        # @param command_name [String] qualified command name
        # @param for_each [Hash, nil] optional sweep declaration of the
        #   form +{ from: "Aggregate.query_name" }+ ; +nil+ leaves the
        #   dispatch as a single-record fire (back-compat default).
        # @param with [Hash, nil] optional attr→value-spec map. Each
        #   value is either a literal scalar (passed through) or a
        #   ValueSpec returned by +from_event+ / +from_pm+ / +from_iter+.
        def dispatch(command_name, for_each: nil, with: nil)
          with_spec = build_with_spec(with)
          for_each_spec = build_for_each_spec(for_each)
          @dispatches << DispatchSpec.new(
            command_name: command_name.to_s,
            with_spec: with_spec,
            for_each_spec: for_each_spec
          )
        end

        # Phase 2.c — write a value into the PM instance's per-instance
        # attributes hash. The same +ValueSpec+ vocabulary as
        # +dispatch ..., with: { ... }+ resolves the value at handler
        # firing time : a literal scalar passes through ; +from_event+
        # reads the upstream event ; +from_pm+ reads a previously-set
        # PM attribute (chained writes within a single handler see
        # earlier writes via the runtime's evaluation order).
        #
        # @param attr [Symbol, String] the PM attribute name
        # @param value [Object, ValueSpec] literal scalar or ValueSpec
        #
        #   set :carrying, "body"
        #   set :steering_target, from_event(:target)
        #   set :tick, from_pm(:tick, default: "0")
        def set(attr, value)
          spec = if value.is_a?(ValueSpec)
                   value
                 else
                   ValueSpec.new(
                     kind: :literal,
                     name: nil,
                     value: value,
                     default: nil
                   )
                 end
          @set_specs << [attr.to_s, spec]
        end

        # Sentinel : at dispatch time, read +event.data[name]+ ; fall back
        # to +default+ if the key is missing. +name+ is a Symbol (the
        # event-attribute key). +default+ is any literal scalar.
        def from_event(name, default: nil)
          ValueSpec.new(
            kind: :from_event,
            name: name.to_sym,
            value: nil,
            default: default
          )
        end

        # Sentinel : at dispatch time, read +pm_instance.data[name]+ ;
        # fall back to +default+ if the key is missing. PM-state writes
        # are a separate (Phase-2.c) concern ; until then, +from_pm+
        # always falls through to +default+ which is identical to the
        # legacy procs' +pm.attributes[:x] || "—"+ pattern.
        def from_pm(name, default: nil)
          ValueSpec.new(
            kind: :from_pm,
            name: name.to_sym,
            value: nil,
            default: default
          )
        end

        # i221-A — Sentinel : at sweep-dispatch time, read the iteration
        # record's +data[field]+ . Only meaningful inside a dispatch that
        # also declares +for_each: { from: "Agg.query" }+ ; absent the
        # for_each, the runtime treats it as a missing key (i221-B will
        # add the runtime expansion).
        #
        #   dispatch "Synapse.Compost",
        #     for_each: { from: "Synapse.cold" },
        #     with: { id: from_iter(:id) }
        def from_iter(field)
          ValueSpec.new(
            kind: :from_iter,
            name: field.to_sym,
            value: nil,
            default: nil
          )
        end

        private

        # i221-A — normalise the +for_each:+ kwarg into a +ForEachSpec+
        # struct. Accepts +{ from: "Aggregate.query_name" }+ ; +nil+
        # passes through (bare / single-record dispatch). Splits the
        # qualified literal on the first dot into +source_aggregate+
        # and +query_name+ ; raises +ArgumentError+ when the literal
        # is malformed (no dot, empty halves) so authors get a loud
        # error rather than a silent runtime miss.
        def build_for_each_spec(for_each)
          return nil if for_each.nil?
          unless for_each.is_a?(Hash)
            raise ArgumentError,
                  "dispatch for_each: must be a Hash like { from: \"Aggregate.query\" }, got #{for_each.inspect}"
          end
          from_value = for_each[:from] || for_each["from"]
          unless from_value.is_a?(String)
            raise ArgumentError,
                  "dispatch for_each: must declare a String `from:` literal, got #{from_value.inspect}"
          end
          dot = from_value.index('.')
          if dot.nil? || dot.zero? || dot == from_value.length - 1
            raise ArgumentError,
                  "dispatch for_each: `from:` literal must be qualified " \
                  "(\"Aggregate.query_name\"), got #{from_value.inspect}"
          end
          ForEachSpec.new(
            source_aggregate: from_value[0...dot],
            query_name: from_value[(dot + 1)..]
          )
        end

        # Normalise the +with:+ hash into an ordered Array<[String, ValueSpec]>.
        # Order preserves declaration order ; the canonical IR carries
        # this as a list of pairs (not an unordered Hash) so byte-equal
        # parity with the Rust dump survives Ruby Hash insertion-order
        # quirks across versions.
        def build_with_spec(with)
          return [] if with.nil? || with.empty?
          with.map do |key, value|
            spec = if value.is_a?(ValueSpec)
                     value
                   else
                     ValueSpec.new(
                       kind: :literal,
                       name: nil,
                       value: value,
                       default: nil
                     )
                   end
            [key.to_s, spec]
          end
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

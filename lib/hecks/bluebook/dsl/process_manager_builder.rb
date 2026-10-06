require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `process_manager "Name" do ... end` block into a `ProcessManager`; its states
      # are derived from its `transition`s (ADR 0025).
      class ProcessManagerBuilder
        GRAMMAR_CONTEXT = "ProcessManager".freeze

        class InvalidProcessManager < StandardError; end

        include WordGate

        # @param name [String] the process manager's own name, as written after `process_manager`
        def initialize(name)
          @name     = name
          @handlers = []
        end

        # Records the event that begins a fresh instance of this process manager.
        #
        # `starts_on Transfer::TransferRequested`: a bare constant, stored as the bare event
        # name (`Naming.event_name_ref`) because `SagaInterpreter` matches an undotted name.
        # A plain String passes through unchanged.
        #
        # @param event_ref [Symbol, String, Module] the event, as a bare constant (a
        #   `ScopedConstant` module `ConstShim` resolves) or quoted text
        # @return [void]
        def starts_on_impl(event_ref)
          @starts_on = Naming.event_name_ref(event_ref)
        end

        # Records the event that closes out this process manager's instance.
        #
        # @param event_ref [Symbol, String, Module] the event, as a bare constant (a
        #   `ScopedConstant` module `ConstShim` resolves) or quoted text
        # @return [void]
        def ends_on_impl(event_ref)
          @ends_on = Naming.event_name_ref(event_ref)
        end

        # Records one leg of the state machine: the event that takes it, the state(s) it
        # applies from, and the dispatches (with optional compensations) it fires.
        #
        # States are derived from the transitions, not declared.
        #
        # @param mapping [Hash] one `event => target_state` pair plus a required `from:` key
        #   naming the source state(s): a `String`, `Symbol`, or an `Array` of them
        # @yield the transition's dispatch body, `instance_eval`'d against a `HandlerBuilder`
        # @return [void]
        # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if `mapping` names
        #   no `from:`
        def transition_impl(mapping, &block)
          mapping = mapping.dup
          from    = mapping.delete(:from)
          refuse_missing_from!(mapping, from)

          handler = HandlerBuilder.new
          handler.instance_eval(&block) if block

          mapping.each do |event_type, target|
            # `event_name_ref` keeps only the final segment: `SagaInterpreter` matches a bare
            # `event.name`, so `Account::AccountDebited` and `AccountDebited` store the same.
            state_transition = StateTransition.new(target: target, from: from)
            expand(Naming.event_name_ref(event_type), state_transition, handler.dispatches).each { |row| @handlers << row }
          end
        end

        # Assembles the declared transitions into a `ProcessManager`, after validating them.
        #
        # @return [Bluebook::ProcessManager] the built process manager, with its own `states`
        #   derived from the declared transitions
        # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if `correlates_by`
        #   is undeclared or names a whole field rather than one scalar, if `starts_on` is
        #   undeclared, if no transition was declared, or if two transitions answer the same event
        #   from the same source state
        def build
          validate!

          ProcessManager.new(
            name:          @name,
            correlates_by: @correlates_by,
            starts_on:     @starts_on,
            ends_on:       @ends_on,
            states:        derived_states,
            handlers:      @handlers
          )
        end

        # Evaluates a `process_manager` block against a fresh builder and returns what it built.
        #
        # @param name [String] the process manager's own name
        # @yield the process manager's body, `instance_eval`'d against a new builder; may be
        #   omitted
        # @return [Bluebook::ProcessManager] the built process manager
        # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] see `#build`
        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # `from:` is required: the saga's admission check tests `from_state` by plain equality,
        # so a transition with no `from:` would match no instance.
        def refuse_missing_from!(mapping, from)
          return unless from.nil?

          raise InvalidProcessManager,
                "#{@name}'s transition #{mapping.inspect} names no from: — a process manager's own " \
                "admission checks a saga instance's CURRENT state exactly, so a transition with no " \
                "from: would match no instance ever, silently"
        end

        # One row per source state, since a `ProcessManagerHandler` carries a single `from_state`.
        def expand(event_type, transition, dispatches)
          sources = transition.from.nil? ? [nil] : Array(transition.from)

          sources.map do |source|
            ProcessManagerHandler.new(
              event_type: event_type,
              from_state: source.to_s,
              to_state:   transition.target,
              dispatches: dispatches
            )
          end
        end

        # First-seen order matters: `pm.states.first` is the state a fresh instance starts in.
        def derived_states
          @handlers.flat_map { |h| [h.from_state, h.to_state] }.reject(&:empty?).uniq
        end

        def validate!
          refuse_bad_correlation!

          if @starts_on.to_s.empty?
            raise InvalidProcessManager, "#{@name} declares no starts_on — " \
                                         "nothing would ever begin it"
          end

          if @handlers.empty?
            raise InvalidProcessManager, "#{@name} declares no transitions — " \
                                         "it would start and then ignore every event"
          end

          refuse_ambiguous_legs!
        end

        def refuse_bad_correlation!
          unless @correlates_by
            raise InvalidProcessManager, "#{@name} declares no correlates_by — " \
                                         "nothing would tie its events to one instance"
          end

          # Names a scalar (`:"end_to_end.value"`), never a whole field or value object.
          # A syntactic check: the dotted spelling leaves no question about the key's type.
          return if @correlates_by.to_s.include?(".")

          raise InvalidProcessManager, "#{@name} correlates_by #{@correlates_by.inspect}, which names a whole " \
                                       "field rather than one of its scalars — say which one, e.g. " \
                                       "#{@correlates_by}.value"
        end

        # A leg is selected by (event, current state), so two legs on the same pair would
        # be picked by declaration order; `from: [...]` fan-out counts.
        def refuse_ambiguous_legs!
          return if MetaValidator.shadow_parsing? # frozen era text is history

          seen = {}
          @handlers.each do |handler|
            key = [handler.event_type, handler.from_state]
            refuse_ambiguous_pair!(handler, seen[key]) if seen[key]
            seen[key] = handler
          end
        end

        def refuse_ambiguous_pair!(handler, earlier)
          raise InvalidProcessManager,
                "#{@name} declares two transitions on #{handler.event_type.inspect} from " \
                "#{handler.from_state.inspect} (=> #{earlier.to_state.inspect} and => " \
                "#{handler.to_state.inspect}) — a leg is selected by (event, current state), so " \
                "only one may answer"
        end

        # The body of one `transition ... do ... end` block; collects its `dispatch` calls.
        class HandlerBuilder
          GRAMMAR_CONTEXT = "Handler".freeze

          attr_reader :dispatches

          include WordGate

          # Starts this handler's own dispatch list empty.
          def initialize = @dispatches = []

          # Records one command this transition dispatches, and, if given a block, the
          # compensation that reverses it.
          #
          # The command is a bare constant; quoted text is accepted only under shadow-parsing.
          #
          # @param command_ref [Symbol, String, Module] the command, as a bare constant
          # @param with [Hash{Symbol => Object}, nil] a projection onto the command's arguments,
          #   as in a policy's `trigger ..., with:`; `nil` forwards the triggering context
          # @yield the `compensates` body, run only if this leg completed
          # @return [Bluebook::DispatchSpec] the dispatch just recorded
          # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if `command_ref`
          #   is quoted text outside shadow-parsing
          def dispatch_impl(command_ref, with: nil, &block)
            refuse_quoted_command!(command_ref)

            spec = DispatchSpec.new(
              command_name: Naming.command_ref(command_ref),
              with_spec:    (with || {}).to_a
            )
            spec.instance_variable_set(:@projection_declared, !with.nil?)
            spec.compensates = compensation_from(block) if block

            @dispatches << spec
            spec
          end

          private

          def refuse_quoted_command!(command_ref)
            return unless command_ref.is_a?(::String) && !MetaValidator.shadow_parsing?

            raise InvalidProcessManager,
                  "dispatch #{command_ref.inspect} is quoted text — give the bare command constant " \
                  "instead, e.g. dispatch Account::Debit"
          end

          # `instance_variable_get`, not a public reader: a reader would be a method the
          # grammar never declares (syntax_conformance_spec).
          def compensation_from(block)
            builder = DispatchBuilder.new
            builder.instance_eval(&block)
            builder.instance_variable_get(:@compensates_spec)
          end

          # The nested scope `dispatch ... do ... end` opens; its one word, `compensates`,
          # takes the same arguments as `dispatch` and resolves in the same saga scope.
          class DispatchBuilder
            GRAMMAR_CONTEXT = "Dispatch".freeze

            include WordGate

            # Records the command that reverses the dispatch this `compensates` block sits inside.
            #
            # @param command_ref [Symbol, String, Module] the compensating command, as a bare
            #   constant (a `ScopedConstant` module `ConstShim` resolves) or, under shadow-parsing,
            #   quoted text
            # @param with [Hash{Symbol => Object}, nil] a projection onto the command's own
            #   arguments, the same shape `HandlerBuilder#dispatch_impl`'s own `with:` takes; `nil`
            #   forwards the triggering context verbatim
            # @return [Bluebook::DispatchSpec] the compensating dispatch just recorded
            # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if `command_ref`
            #   is quoted text outside shadow-parsing
            def compensates_impl(command_ref, with: nil)
              if command_ref.is_a?(::String) && !MetaValidator.shadow_parsing?
                raise InvalidProcessManager,
                      "compensates #{command_ref.inspect} is quoted text — give the bare command constant " \
                      "instead, e.g. compensates Account::Credit"
              end

              @compensates_spec = DispatchSpec.new(
                command_name: Naming.command_ref(command_ref),
                with_spec:    (with || {}).to_a
              )
            end
          end
        end
      end
    end
  end
end

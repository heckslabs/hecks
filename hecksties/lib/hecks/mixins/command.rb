require_relative "command/lifecycle_steps"
require_relative "command/reference_validation"

module Hecks
  # Hecks::Command
  #
  # Mixin for generated command classes. Orchestrates the full command lifecycle:
  # run guard policy, run handler, execute call (with optional middleware),
  # persist aggregate, emit event, and record event.
  # The generated call method is pure domain logic — just build and return
  # the aggregate.
  #
  # == Lifecycle
  #
  # When +.call+ is invoked the following steps execute in order:
  # 1. Guard policy (+guarded_by+) -- rejects unauthorized commands
  # 2. Handler callback (+handler+) -- optional pre-processing hook
  # 3. Precondition checks -- domain invariants that must hold before execution
  # 4. +#call+ (user-defined) -- builds/modifies the aggregate; may be wrapped by command bus middleware
  # 5. Postcondition checks -- domain invariants that must hold after execution
  # 6. Persist aggregate via the wired repository
  # 7. Emit event via the wired event bus
  # 8. Record event in the event recorder for the aggregate
  #
  # == Chaining
  #
  # Commands can be chained fluently with +#then+. If any step raises, the
  # chain short-circuits and the error is captured on the originating command.
  #
  # == Usage
  #
  #   class CreatePizza
  #     emits "CreatedPizza"
  #
  #     def call
  #       Pizza.new(name: name)
  #     end
  #   end
  #
  #   cmd = CreatePizza.call(name: "Margherita")
  #   cmd.aggregate  # => #<Pizza>
  #   cmd.event      # => #<CreatedPizza>
  #
  module Command
    # Hook called when a class includes +Hecks::Command+. Extends the class
    # with +ClassMethods+ and defines +aggregate+, +event+, and +events+ readers
    # on instances so callers can inspect command results.
    #
    # +event+ returns the first (or only) emitted event for backward compatibility.
    # +events+ returns all emitted events as an array.
    #
    # @param base [Class] the class including this module
    # @return [void]
    def self.included(base)
      base.extend(ClassMethods)
      base.attr_reader :aggregate, :event, :events
      base.include(ReferenceValidation)
    end

    # Class-level DSL and execution entry point for command classes.
    #
    # Provides configuration accessors (+repository+, +event_bus+, +handler+,
    # +guarded_by+, +event_recorder+, +aggregate_type+, +command_bus+) that
    # are wired during boot by the Hecks runtime.
    module ClassMethods
      attr_accessor :repository, :event_bus, :handler, :guarded_by,
                    :event_recorder, :aggregate_type, :command_bus,
                    :reference_meta, :reference_authorizer

      # Declares the event name(s) emitted when this command succeeds.
      # The event class(es) are resolved at runtime from the aggregate's Events module.
      # Pass multiple names to emit more than one event per command execution.
      #
      # @param event_names [Array<String>] one or more PascalCase event names (e.g. "CreatedPizza")
      # @return [void]
      def emits(*event_names)
        @event_names = event_names
      end

      # Returns the declared event name for this command (first event, for backward compat).
      #
      # @return [String, nil] the first event name set via +emits+, or nil if none declared
      def event_name
        @event_names&.first
      end

      # Returns all declared event names for this command.
      #
      # @return [Array<String>] all event names set via +emits+, or empty array if none declared
      def event_names
        @event_names || []
      end

      # Returns the list of registered precondition checks.
      # Preconditions are validated before the command's +#call+ executes.
      #
      # @return [Array<DomainModel::Behavior::Condition>] registered preconditions
      def preconditions
        @preconditions ||= []
      end

      # Returns the list of registered postcondition checks.
      # Postconditions are validated after +#call+ returns, receiving the
      # before and after states of the aggregate.
      #
      # @return [Array<DomainModel::Behavior::Condition>] registered postconditions
      def postconditions
        @postconditions ||= []
      end

      # Registers a precondition that must hold before the command executes.
      # The block is evaluated in the context of the command instance via
      # +instance_exec+, so it has access to command attributes.
      #
      # @param message [String] human-readable description of the precondition (used in error messages)
      # @yield block that returns truthy if the precondition holds
      # @return [void]
      # @raise [Hecks::PreconditionError] at execution time if the block returns falsey
      def precondition(message, &block)
        preconditions << DomainModel::Behavior::Condition.new(message: message, block: block)
      end

      # Registers a postcondition that must hold after the command executes.
      # The block receives the aggregate state before and after +#call+.
      #
      # @param message [String] human-readable description of the postcondition (used in error messages)
      # @yield [before, after] block that returns truthy if the postcondition holds
      # @yieldparam before [Object, nil] the aggregate before command execution (nil for creates)
      # @yieldparam after [Object] the aggregate after command execution
      # @return [void]
      # @raise [Hecks::PostconditionError] at execution time if the block returns falsey
      def postcondition(message, &block)
        postconditions << DomainModel::Behavior::Condition.new(message: message, block: block)
      end

      # Resolves the event class constant from the declared event name (first event).
      # Navigates up from the command's namespace to the aggregate module,
      # then looks up +Events::<event_name>+.
      #
      # @return [Class] the event class (e.g. +Pizza::Events::CreatedPizza+)
      # @raise [NameError] if the event class cannot be found
      def event_class
        agg_module = name.split("::")[0..-3].join("::")
        Object.const_get("#{agg_module}::Events::#{event_name}")
      end

      # Resolves all event class constants from the declared event names.
      #
      # @return [Array<Class>] all event classes
      # @raise [NameError] if any event class cannot be found
      def event_classes
        agg_module = name.split("::")[0..-3].join("::")
        event_names.map { |en| Object.const_get("#{agg_module}::Events::#{en}") }
      end

      # Executes the full command lifecycle: guard, handler, preconditions,
      # call, postconditions, persist, emit, and record.
      #
      # If a +command_bus+ with middleware is configured, the +#call+ step is
      # dispatched through the middleware chain.
      #
      # @param attrs [Hash] keyword arguments forwarded to the command constructor
      # @return [self] the command instance with +#aggregate+ and +#event+ populated
      # @raise [Hecks::GuardRejected] if the guard policy rejects the command
      # @raise [Hecks::PreconditionError] if any precondition fails
      # @raise [Hecks::PostconditionError] if any postcondition fails
      def call(**attrs)
        cmd = new(**attrs)
        lifecycle_pipeline.each { |step| step.call(cmd) }
        cmd
      end

      def lifecycle_pipeline
        Command::LifecycleSteps::PIPELINE
      end

      # Runs the command through validation steps (guard, precondition, call,
      # postcondition) without persisting, emitting, or recording. Builds the
      # event(s) that would have been emitted and attaches them to the command.
      #
      # @param attrs [Hash] command attributes
      # @return [self] the command instance with +#aggregate+, +#event+, and +#events+ populated
      def dry_call(**attrs)
        cmd = new(**attrs)
        Command::LifecycleSteps::DRY_RUN_PIPELINE.each { |step| step.call(cmd) }
        built = cmd.send(:build_events)
        cmd.instance_variable_set(:@events, built)
        cmd.instance_variable_set(:@event, built.first)
        cmd
      end
    end

    # Chain commands fluently. Yields self to block, returns the block's
    # result (which should be another command). Propagates chain history.
    # If any step in the chain raises, the error is captured and subsequent
    # +then+ calls are skipped (short-circuit).
    #
    # @yield [self] the current command instance
    # @yieldreturn [Hecks::Command] the next command in the chain
    # @return [Hecks::Command] the next command, or self if an error occurred
    #
    # @example
    #   AiModel.register(name: "X").then { |cmd| Assessment.initiate(model_id: cmd.id) }
    def then
      return self if @chain_error
      begin
        result = yield(self)
        result.instance_variable_set(:@chain_steps, steps + [result]) if result.respond_to?(:aggregate)
        result
      rescue => e
        @chain_error = e
        self
      end
    end

    # Returns true if no error occurred during chaining.
    #
    # @return [Boolean]
    def success? = @chain_error.nil?

    # Returns the list of command steps in this chain.
    #
    # @return [Array<Hecks::Command>] all commands executed in the chain
    def steps = @chain_steps || [self]

    # Returns the last command in the chain.
    #
    # @return [Hecks::Command]
    def last = steps.last

    # Returns the error captured during chaining, if any.
    #
    # @return [Exception, nil]
    def error = @chain_error

    # Delegates unknown methods to the aggregate for backward compatibility.
    # This allows callers to access aggregate attributes directly on the command
    # result (e.g. +cmd.name+ instead of +cmd.aggregate.name+).
    #
    # @param name [Symbol] the method name
    # @param args [Array] positional arguments
    # @param kwargs [Hash] keyword arguments
    # @param block [Proc] optional block
    # @return [Object] the return value from the aggregate method
    # @raise [NoMethodError] if neither the command nor the aggregate responds
    def method_missing(name, *args, **kwargs, &block)
      if aggregate&.respond_to?(name)
        kwargs.empty? ? aggregate.send(name, *args, &block) : aggregate.send(name, *args, **kwargs, &block)
      else
        super
      end
    end

    # Returns true if the aggregate responds to the given method.
    #
    # @param name [Symbol] the method name to check
    # @param include_private [Boolean] whether to include private methods
    # @return [Boolean]
    def respond_to_missing?(name, include_private = false)
      aggregate&.respond_to?(name, include_private) || super
    end

    private

    # Returns the repository wired to this command's class.
    #
    # @return [Object] the repository instance (typically a Hecks memory or SQL adapter)
    def repository
      self.class.repository
    end

    # Evaluates all registered preconditions in the command instance context.
    # Raises +Hecks::PreconditionError+ on the first failure.
    #
    # @return [void]
    # @raise [Hecks::PreconditionError] if any precondition block returns falsey
    def check_preconditions
      self.class.preconditions.each do |cond|
        unless instance_exec(&cond.block)
          raise Hecks::PreconditionError, "Precondition failed: #{cond.message}"
        end
      end
    end

    # Evaluates all registered postconditions, comparing the aggregate state
    # before and after command execution.
    #
    # @param before [Object, nil] the aggregate state before execution
    # @param after [Object] the aggregate state after execution
    # @return [void]
    # @raise [Hecks::PostconditionError] if any postcondition block returns falsey
    def check_postconditions(before, after)
      self.class.postconditions.each do |cond|
        unless cond.block.call(before, after)
          raise Hecks::PostconditionError, "Postcondition failed: #{cond.message}"
        end
      end
    end

    # Attempts to find the existing aggregate for before/after postcondition
    # comparison. Looks for an instance variable ending in +_id+ and uses it
    # to fetch from the repository.
    #
    # @return [Object, nil] the existing aggregate, or nil if not found or no postconditions
    def find_existing_for_postcondition
      return nil if self.class.postconditions.empty?
      # Try to find the existing aggregate for before/after comparison
      id_method = instance_variables.find { |v| v.to_s.end_with?("_id") }
      return nil unless id_method
      id_val = instance_variable_get(id_method)
      repository&.find(id_val) rescue nil
    end

    # Executes the guard policy if one is configured via +guarded_by+.
    # Resolves the policy class from the aggregate's Policies module.
    #
    # @return [void]
    # @raise [Hecks::GuardRejected] if the policy returns falsey
    def run_guard
      policy_name = self.class.guarded_by
      return unless policy_name

      agg_module = self.class.name.split("::")[0..-3].join("::")
      policy_class = Object.const_get("#{agg_module}::Policies::#{policy_name}")
      result = policy_class.new.call(self)
      unless result
        raise Hecks::GuardRejected, "Guard #{policy_name} rejected #{self.class.name.split('::').last}"
      end
    end

    # Invokes the optional handler callback configured on the command class.
    # Handlers are typically set during boot for cross-cutting concerns.
    #
    # @return [void]
    def run_handler
      self.class.handler&.call(self)
    end

    # Persists the aggregate via the wired repository. Stamps created_at or
    # updated_at timestamps automatically if the aggregate supports them.
    #
    # @return [void]
    def persist_aggregate
      return unless aggregate
      if aggregate.respond_to?(:stamp_created!) && aggregate.created_at.nil?
        aggregate.stamp_created!
      elsif aggregate.respond_to?(:stamp_updated!)
        aggregate.stamp_updated!
      end
      repository.save(aggregate)
    end

    # Constructs a single event instance from the given event class.
    # Introspects the event class constructor to map command and aggregate
    # attributes into event parameters.
    #
    # @param event_class [Class] the event class to instantiate
    # @return [Object] the constructed event instance
    def build_event_for(event_class)
      event_params = event_class.instance_method(:initialize).parameters.map { |_, n| n }
      attrs = {}
      event_params.each do |param|
        if param == :aggregate_id && aggregate
          attrs[param] = aggregate.id
        elsif respond_to?(param, true)
          attrs[param] = send(param)
        elsif aggregate&.respond_to?(param)
          attrs[param] = aggregate.send(param)
        end
      end
      event_class.new(**attrs)
    end

    # Constructs all events declared via +emits+ without publishing them.
    #
    # @return [Array<Object>] all constructed event instances
    def build_events
      self.class.event_classes.map { |klass| build_event_for(klass) }
    end

    # Constructs the first event declared via +emits+ without publishing it.
    # Preserved for backward compatibility with dry_call and internal use.
    #
    # @return [Object] the constructed event instance
    def build_event
      build_event_for(self.class.event_class)
    end

    # Builds and publishes all events declared via +emits+ on the event bus.
    # Sets +@event+ to the first event for backward compatibility,
    # and +@events+ to the full array.
    #
    # @return [Array<Object>] all constructed and published event instances
    def emit_event
      @events = build_events
      @event = @events.first
      @events.each { |evt| self.class.event_bus&.publish(evt) }
      @events
    end

    # Records the emitted event in the event recorder for the aggregate,
    # enabling event sourcing and audit trails.
    #
    # @return [void]
    def record_event_for_aggregate
      recorder = self.class.event_recorder
      agg_type = self.class.aggregate_type
      recorder.record(agg_type, aggregate.id, @event) if recorder && aggregate
    end
  end
end

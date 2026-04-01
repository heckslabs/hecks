require_relative "runtime/port_setup"
require_relative "runtime/gate_enforcer"
require_relative "runtime/repository_setup"
require_relative "runtime/policy_setup"
require_relative "runtime/subscriber_setup"
require_relative "runtime/view_setup"
require_relative "runtime/workflow_setup"
require_relative "runtime/saga_store"
require_relative "runtime/saga_runner"
require_relative "runtime/saga_setup"
require_relative "runtime/constant_hoisting"
require_relative "runtime/connection_setup"
require_relative "runtime/service_setup"
require_relative "runtime/auth_coverage_check"
require_relative "runtime/reference_authorizer_check"

module Hecks
  # Hecks::Runtime
  #
  # The runtime container that wires a domain to adapters, dispatches
  # commands, publishes events, and executes policies. Defaults to memory
  # adapters for all aggregates. Created via Hecks.load(domain).
  #
  #   app = Hecks.load(domain)
  #   app["Pizza"].all
  #   Pizza.create(name: "Margherita")
  #
  # Custom adapters:
  #   app = Hecks.load(domain) do
  #     adapter "Pizza", my_sql_repo
  #   end
  #
  # The central runtime container for a Hecks domain. Orchestrates the full
  # lifecycle of a domain application: wiring repositories to aggregates,
  # setting up the command bus with middleware, registering event-driven
  # policies and subscribers, hoisting aggregate constants to top-level,
  # and establishing cross-domain connections.
  #
  # Runtime is the object returned by +Hecks.boot+ and +Hecks.load+.
  # It holds all repositories, the event bus, and the command bus for a
  # single domain. In multi-domain setups, each domain gets its own Runtime
  # instance, potentially sharing a filtered event bus.
  #
  # Includes several setup mixins that each handle one aspect of wiring:
  # - PortSetup -- wires aggregate ports (command methods, query methods, repository methods)
  # - RepositorySetup -- creates memory-backed repositories for each aggregate
  # - PolicySetup -- registers event-triggered policies on the event bus
  # - SubscriberSetup -- registers event subscribers defined in the DSL
  # - ViewSetup -- sets up read-model views
  # - WorkflowSetup -- wires multi-step workflow definitions
  # - ConstantHoisting -- promotes aggregate classes to top-level constants
  # - ConnectionSetup -- wires cross-domain event connections (listens_to/sends_to)
  class Runtime
    include HecksTemplating::NamingHelpers
      include PortSetup
      include RepositorySetup
      include PolicySetup
      include SubscriberSetup
      include ViewSetup
      include WorkflowSetup
      include ConstantHoisting
      include ConnectionSetup
      include AuthCoverageCheck
      include ReferenceCoverageCheck
      include SagaSetup

      # @return [Hecks::DomainModel::Structure::Domain] the domain IR object this runtime is wired to
      attr_reader :domain

      # @return [Hecks::EventBus] the event bus used for publishing and subscribing to domain events
      attr_reader :event_bus

      # @return [Hecks::Commands::CommandBus] the command bus that dispatches commands through middleware
      attr_reader :command_bus

      # Boots the runtime: wires repositories, policies, subscribers, and the command bus.
      # Evaluates an optional configuration block in the context of the runtime instance,
      # allowing adapter overrides and middleware registration before wiring completes.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain] the compiled domain IR object
      # @param port [Symbol, nil] optional port name (reserved for future use)
      # @param event_bus [Hecks::EventBus, nil] optional shared event bus; creates a new one if nil
      # @yield optional configuration block evaluated in the runtime's instance context
      # @return [Hecks::Runtime]
      def initialize(domain, gate: nil, event_bus: nil, hecksagon: nil, &config)
        @domain = domain
        @gate_name = gate
        @hecksagon = hecksagon || Hecks.last_hecksagon
        @mod_name = domain_module_name(domain.name)
        @mod = Object.const_get(@mod_name)
        @mod.extend(Hecks::DomainConnections) unless @mod.respond_to?(:connections)
        @event_bus = event_bus || EventBus.new
        @repositories = {}
        @adapter_overrides = {}
        @async_handler = nil
        @runtime_options = {}

        instance_eval(&config) if config

        setup_repositories
        setup_command_bus
        setup_policies
        setup_subscribers
        setup_views
        setup_connections
        wire_ports!
        ServiceSetup.bind(@domain, @mod, @command_bus)
        setup_workflows
        setup_sagas
        hoist_constants
      end

      # Register command bus middleware. Middleware wraps every command dispatch,
      # allowing cross-cutting concerns like logging, authorization, or auditing.
      #
      # @param name [Symbol, String, nil] optional middleware name for identification
      # @yield block that receives the command and a +next_middleware+ callable
      # @return [void]
      def use(name = nil, &block)
        @command_bus.use(name, &block)
      end

      # Configuration DSL: override the default memory adapter for a specific aggregate
      # with a custom repository object (e.g., SQL-backed repository).
      #
      # @param aggregate_name [String, Symbol] the aggregate name (e.g., "Pizza")
      # @param adapter_obj [Object] a repository object that responds to CRUD methods
      # @return [void]
      def adapter(aggregate_name, adapter_obj)
        @adapter_overrides[aggregate_name.to_s] = adapter_obj
      end

      # Configuration DSL: enable an infrastructure option for a specific aggregate.
      # Used to configure cross-cutting concerns like versioning and attachments
      # that were previously baked into the domain IR.
      #
      #   app = Hecks.load(domain) do
      #     enable "Document", :versioned
      #     enable "Document", :attachable
      #   end
      #
      # @param aggregate_name [String, Symbol] the aggregate name
      # @param option [Symbol] the option to enable (e.g., :versioned, :attachable)
      # @return [void]
      def enable(aggregate_name, option)
        name = aggregate_name.to_s
        @runtime_options[name] ||= {}
        @runtime_options[name][option] = true
      end

      # Retrieve the repository for a named aggregate.
      #
      # @param name [String, Symbol] the aggregate name (e.g., "Pizza")
      # @return [Object] the repository (memory adapter or custom adapter) for the aggregate
      def [](name)
        @repositories[name.to_s]
      end

      # Execute a command through the command bus, passing it through all registered
      # middleware before reaching the command runner.
      #
      # @param command_name [String, Symbol] the fully qualified command name (e.g., "CreatePizza")
      # @param attrs [Hash] the command attributes/parameters
      # @return [Object] the result of the command execution (typically the affected entity)
      def run(command_name, **attrs)
        @command_bus.dispatch(command_name, **attrs)
      end

      # Preview what a command would do without persisting, emitting, or recording.
      # Runs guards, preconditions, the call body, and postconditions. Returns a
      # DryRunResult with the aggregate, event, and reactive chain that would fire.
      #
      #   result = app.dry_run("CreatePizza", name: "Margherita")
      #   result.aggregate.name  # => "Margherita"
      #   result.event           # => #<CreatedPizza ...>
      #
      # @param command_name [String] the command name (e.g., "CreatePizza")
      # @param attrs [Hash] the command attributes
      # @return [Hecks::DryRunResult]
      # @raise [Hecks::GuardRejected, Hecks::PreconditionError, Hecks::PostconditionError]
      def dry_run(command_name, **attrs)
        cmd_class = @command_bus.resolve_command_class(command_name)
        cmd = cmd_class.dry_call(**attrs)
        chain = trace_reactive_chain(command_name)
        DryRunResult.new(command: cmd, aggregate: cmd.aggregate, event: cmd.event, reactive_chain: chain)
      end

      # Register an async handler for policies marked +async: true+ in the DSL.
      # The handler receives an event and is responsible for scheduling deferred work
      # (e.g., enqueuing a background job).
      #
      # @yield [event] block that handles async event processing
      # @return [void]
      def async(&handler)
        @async_handler = handler
      end

      # Subscribe to a named event on the event bus.
      #
      # @param event_name [String, Symbol] the event name to subscribe to (e.g., "PizzaCreated")
      # @yield [event] block called when the event is published
      # @return [void]
      def on(event_name, &handler)
        @event_bus.subscribe(event_name, &handler)
      end

      # Returns all events that have been published on the event bus since boot.
      #
      # @return [Array<Hash>] list of event hashes with :name and :payload keys
      def events
        @event_bus.events
      end

      # Replace a repository adapter for a named aggregate. Used by extension gems
      # (e.g., hecks_sqlite) to swap memory adapters for persistent ones after boot.
      # Re-wires the aggregate's port methods after swapping.
      #
      # @param aggregate_name [String, Symbol] the aggregate name (e.g., "Pizza")
      # @param repo [Object] the replacement repository object
      # @return [void]
      def swap_adapter(aggregate_name, repo)
        name = aggregate_name.to_s
        @repositories[name] = repo
        wire_aggregate!(name)
      end

      # Apply an extension to the live runtime without rebooting.
      #
      # Looks up the extension hook in the registry and calls it with the
      # current domain module, domain IR, and this runtime instance. The hook
      # can register middleware, swap adapters, or subscribe to events — all
      # take effect immediately on the next command dispatch.
      #
      #   runtime.extend(:logging)
      #   runtime.extend(:sqlite)
      #   runtime.extend(:tenancy)
      #
      # @param name [Symbol] the registered extension name
      # @param kwargs [Hash] options (currently unused, reserved for future extensions)
      # @return [void]
      # @raise [RuntimeError] if the extension is not registered
      def extend(name, **kwargs)
        # Auto-discover extensions if registry is empty
        if Hecks.extension_registry.empty?
          require "hecks/runtime/load_extensions"
          Hecks::LoadExtensions.require_all
        end
        hook = Hecks.extension_registry[name.to_sym]
        raise "Unknown extension: #{name}. Available: #{Hecks.extension_registry.keys.join(', ')}" unless hook
        # Set connection config on the module so the hook can read it
        if kwargs.any? && @mod.respond_to?(:connections)
          @mod.connections[:sends] << { name: name.to_sym, **kwargs }
        end
        hook.call(@mod, @domain, self, **kwargs)
        puts "#{name} extension applied"
      end

      # Returns a human-readable summary of this runtime instance, showing the
      # domain name and number of wired repositories.
      #
      # @return [String] inspection string
      def inspect
        "#<Hecks::Runtime \"#{@domain.name}\" (#{@repositories.size} repositories)>"
      end

      private

      # Creates the command bus, binding it to the domain and event bus.
      # The command bus dispatches commands to the appropriate aggregate
      # command runner and publishes resulting events.
      #
      # @return [void]
      def setup_command_bus
        @command_bus = Commands::CommandBus.new(
          domain: @domain,
          event_bus: @event_bus
        )
      end

      def trace_reactive_chain(command_name)
        return [] unless defined?(Hecks::FlowGenerator)
        flows = Hecks::FlowGenerator.new(@domain).trace_flows
        flow = flows.find { |f| f[:steps]&.first&.dig(:command) == command_name.to_s }
        return [] unless flow
        flow[:steps].drop(1)
      end
    end

  # Backward compatibility alias so existing code referencing
  # +Hecks::Application+ continues to work.
  Application = Runtime
end

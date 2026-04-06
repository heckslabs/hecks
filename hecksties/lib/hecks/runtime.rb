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
require_relative "runtime/extension_dispatch"
require_relative "runtime/configuration_dsl"
require_relative "runtime/command_dispatch"
  # Hecks::Runtime
  #
  # The runtime container that wires a domain to adapters, dispatches
  # commands, publishes events, and executes policies. Created via
  # Hecks.boot or Hecks.load.
  #
  #   app = Hecks.boot(__dir__)
  #   app["Pizza"].all
  #   Pizza.create(name: "Margherita")
  #

module Hecks
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
    include ExtensionDispatch
    include ConfigurationDSL
    include CommandDispatch

    attr_reader :domain, :event_bus, :command_bus

    # @param domain [Hecks::DomainModel::Structure::Domain] the domain IR
    # @param gate [Symbol, nil] optional gate name
    # @param event_bus [Hecks::EventBus, nil] optional shared event bus
    # @param hecksagon [Hecksagon::Structure::Hecksagon, nil] optional hecksagon IR
    # @yield optional configuration block
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
      @runtime_options = {}
      @async_handler = nil

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
      apply_hecksagon_capabilities
    end

    def inspect
      "#<Hecks::Runtime \"#{@domain.name}\" (#{@repositories.size} repositories)>"
    end

    private

    def runtime_option?(aggregate_name, option)
      (@runtime_options || {}).dig(aggregate_name.to_s, option) || false
    end

    def setup_command_bus
      @command_bus = Commands::CommandBus.new(
        domain: @domain,
        event_bus: @event_bus
      )
    end
  end

  Application = Runtime
end

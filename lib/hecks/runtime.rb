# Load runtime implementation files from the Runtime chapter definition.
# The chapter's aggregate list drives which files are required — no
# hand-written require tree needed.
require "hecks/chapters/runtime"
Hecks::Chapters.load_chapter(
  Hecks::Chapters::Runtime,
  base_dir: __dir__
)

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

require "hecks/runtime/projection_setup"
require "hecks/runtime/projection"

module Hecks
  # Hecks::Runtime
  #
  # The runtime container that wires a domain to adapters, dispatches commands, publishes events, and runs policies.
  #
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
    include AdapterWiring
    include ProjectionSetup

    attr_reader :domain, :event_bus, :command_bus, :actor_system

    # @param domain [Hecks::BluebookModel::Structure::Domain] the domain IR
    # @param gate [Symbol, nil] optional gate name
    # @param event_bus [Hecks::EventBus, nil] optional shared event bus
    # @param hecksagon [Hecksagon::Structure::Hecksagon, nil] optional hecksagon IR
    # @yield optional configuration block
    # @return [Hecks::Runtime]
    def initialize(domain, gate: nil, event_bus: nil, hecksagon: nil, &config)
      @domain = domain
      @gate_name = gate
      @hecksagon = hecksagon || Hecks.last_hecksagon
      @mod_name = bluebook_module_name(domain.name)
      @mod = Object.const_get(@mod_name)
      @mod.extend(Hecks::BluebookConnections) unless @mod.respond_to?(:connections)
      @event_bus = event_bus || EventBus.new
      @repositories = {}
      @adapter_overrides = {}
      @runtime_options = {}
      @async_handler = nil

      instance_eval(&config) if config

      setup_repositories
      setup_command_bus
      setup_projections
      setup_policies
      setup_subscribers
      setup_views
      setup_connections
      wire_ports!
      ServiceSetup.bind(@domain, @mod, @command_bus)
      setup_workflows
      setup_sagas
      hoist_constants
      setup_actor_system
      apply_hecksagon_capabilities
    end

    def inspect
      "#<Hecks::Runtime \"#{@domain.name}\" (#{@repositories.size} repositories)>"
    end

    private

    def runtime_option?(aggregate_name, option)
      (@runtime_options || {}).dig(aggregate_name.to_s, option) || false
    end

    def setup_actor_system
      require "hecks/runtime/actor/actor_system"
      @actor_system = Actor::ActorSystem.new(self)
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

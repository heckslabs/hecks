
module Hecks
  module Commands
    # Hecks::Commands::CommandRunner
    #
    # LEGACY -- replaced by CommandBus, which adds middleware support.
    # Kept for backward compatibility. New code should use CommandBus instead.
    #
    # Dispatches commands through the domain. Resolves command and event classes
    # from the domain module namespace, creates events by mapping command attributes
    # to event constructor parameters, and publishes them on the event bus.
    #
    # == Usage
    #
    #   runner = CommandRunner.new(domain: domain, repositories: repos, event_bus: bus)
    #   runner.run("CreatePizza", name: "Margherita")
    #   # => #<PizzasDomain::Pizza::Events::CreatedPizza>
    #
    class CommandRunner
      include HecksTemplating::NamingHelpers
      include CommandResolver
      # Initializes the runner with a domain definition, repositories, and event bus.
      #
      # @param domain [Hecks::BluebookModel::Structure::Domain] the domain IR containing
      #   aggregate, command, and event metadata
      # @param repositories [Hash] a hash of aggregate name to repository instance
      #   (not used directly in dispatch, but available for future extension)
      # @param event_bus [Hecks::EventBus] the event bus for publishing domain events
      def initialize(domain:, repositories:, event_bus:)
        @domain = domain
        @repositories = repositories
        @event_bus = event_bus
        @mod = Object.const_get(bluebook_module_name(domain.name))
      end

      # Dispatches a command by name, creates the corresponding event, and publishes it.
      #
      # Resolves the command and event definitions from the domain IR, instantiates
      # the command with the given attributes, builds a matching event by extracting
      # overlapping attributes, and publishes the event on the event bus.
      #
      # @param command_name [String, Symbol] the command name (e.g., "CreatePizza")
      # @param attrs [Hash] keyword arguments passed to the command constructor
      # @return [Object] the domain event that was created and published
      # @raise [RuntimeError] if the command name cannot be found in any aggregate
      def run(command_name, **attrs)
        agg_def, cmd_def, event_def = resolve(command_name)

        cmd_class = resolve_class(agg_def.name, command_name)
        command = cmd_class.new(**attrs)

        event_class = resolve_event_class(agg_def.name, event_def.name)
        event_attrs = extract_event_attrs(command, event_class)
        event = event_class.new(**event_attrs)

        @event_bus.publish(event)

        event
      end

      end
  end
end

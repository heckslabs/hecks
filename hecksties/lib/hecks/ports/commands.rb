  # Hecks::Commands
  #
  # Groups command dispatch infrastructure: the CommandBus, CommandRunner,
  # and CommandMethods mixin that wires command class methods onto aggregates.
  #
  # This module serves as the entry point for binding command infrastructure
  # to aggregate classes during application boot. It delegates to CommandMethods
  # for the actual wiring of repositories, event buses, and shortcut methods.
  #
  # == Architecture
  #
  # - CommandBus -- dispatches commands through a middleware pipeline
  # - CommandRunner -- legacy dispatcher (no middleware), kept for backward compat
  # - CommandMethods -- wires command classes to repos/buses and creates shortcut methods
  #
  # == Usage
  #
  #   Commands.bind(agg_class, aggregate, bus, repo, defaults)
  #   # Now agg_class has shortcut methods like .create, .update, .delete
  #
  #   Commands.bind_shortcuts(agg_class, aggregate) { |cmd| executor_proc }
  #   # Creates shortcut methods using a custom executor
  #
module Hecks
  module Commands
      autoload :CommandBus,     "hecks/ports/commands/command_bus"
      autoload :CommandRunner,  "hecks/ports/commands/command_runner"
      autoload :CommandMethods, "hecks/ports/commands/command_methods"

      # Wires command infrastructure onto an aggregate class.
      #
      # Delegates to CommandMethods.bind, which auto-includes the Hecks::Command
      # mixin into each command class, sets up repository/event bus references,
      # and creates shortcut class and instance methods on the aggregate.
      #
      # @param klass [Class] the aggregate class to receive shortcut methods
      #   (e.g., +PizzasDomain::Pizza+)
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the aggregate
      #   definition from the domain IR, containing command/event metadata
      # @param bus [Hecks::Commands::CommandBus] the command bus for middleware dispatch
      # @param repo [Object] the repository instance for this aggregate
      # @param defaults [Hash] default attribute values to merge into commands
      # @return [void]
      def self.bind(klass, aggregate, bus, repo, defaults)
        CommandMethods.bind(klass, aggregate, bus, repo, defaults)
      end

      # Creates shortcut class methods on the aggregate without full command wiring.
      #
      # Unlike +bind+, this does not set up repositories or event buses on command
      # classes. Instead, it yields each command definition and expects a block that
      # returns a callable executor. Useful for playground/session contexts where
      # commands are dispatched through a different mechanism.
      #
      # @param klass [Class] the aggregate class to receive shortcut methods
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the aggregate
      #   definition from the domain IR
      # @yield [cmd] called for each command defined on the aggregate
      # @yieldparam cmd [Hecks::DomainModel::Behavior::Command] the command definition
      # @yieldreturn [Proc] a callable that accepts a keyword hash and executes the command
      # @return [void]
      def self.bind_shortcuts(klass, aggregate, &block)
        CommandMethods.bind_shortcuts(klass, aggregate, &block)
      end
  end
end

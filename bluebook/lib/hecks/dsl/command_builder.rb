module Hecks
  module DSL

    # Hecks::DSL::CommandBuilder
    #
    # DSL builder for command definitions. Collects attributes, read models,
    # external systems, actors, an optional handler block, and an optional
    # guard policy reference, then builds a DomainModel::Behavior::Command.
    #
    # Part of the DSL layer, nested under AggregateBuilder. Each command
    # automatically gets a corresponding domain event inferred by name.
    #
    #   builder = CommandBuilder.new("CreatePizza")
    #   builder.attribute :name, String
    #   builder.guarded_by "MustBeAdmin"
    #   builder.read_model "Menu & Availability"
    #   builder.actor "Customer"
    #   cmd = builder.build  # => #<Command name="CreatePizza" ...>
    #   cmd.inferred_event_name  # => "CreatedPizza"
    #
    # Builds a DomainModel::Behavior::Command from DSL declarations.
    #
    # CommandBuilder collects all facets of a command definition: its input
    # attributes, an optional handler or call body, a guard policy reference,
    # read model dependencies, external system dependencies, actors (roles),
    # static field assignments (+sets+), and pre/postconditions. The +#build+
    # method assembles these into an immutable Command IR object.
    #
    # Includes AttributeCollector for the +attribute+, +list_of+, and
    # +reference_to+ DSL methods.
    class CommandBuilder
      Structure = DomainModel::Structure
      Behavior  = DomainModel::Behavior

      include AttributeCollector
      include Describable

      # @return [Array<DomainModel::Structure::Attribute>] the command's input attributes
      attr_reader :attributes

      # Initialize a new command builder with the given command name.
      #
      # Sets up empty collections for all command facets.
      #
      # @param name [String] the command name (e.g. "CreatePizza", "UpdateAccount")
      def initialize(name)
        @name = name
        @attributes = []
        @references = []
        @handler = nil
        @call_body = nil
        @guard_name = nil
        @read_models = []
        @external_systems = []
        @actors = []
        @sets = {}
        @preconditions = []
        @postconditions = []
        @emits = nil
      end

      # Set the call body block executed when the command runs.
      #
      # The call body is a lightweight inline handler evaluated in the context
      # of the command runner. Use this for simple logic; use +handler+ for
      # more complex execution.
      #
      # @yield block executed when the command is dispatched
      # @return [void]
      def call(&block)
        @call_body = block
      end

      # Set a custom handler block for command execution.
      #
      # The handler block receives the command and aggregate and performs
      # the domain logic. Mutually usable with +call+, though +handler+
      # takes precedence when both are set.
      #
      # @yield block that implements the command's domain logic
      # @return [void]
      def handler(&block)
        @handler = block
      end

      # Declare explicit event name(s) emitted when this command succeeds.
      # Overrides the default inferred past-tense event name. Pass multiple
      # names when a single command should emit more than one event.
      #
      # @param names [Array<String>] one or more PascalCase event names
      # @return [void]
      #
      # @example Single explicit event
      #   emits "PizzaCreated"
      #
      # @example Multiple events
      #   emits "PizzaCreated", "MenuUpdated"
      def emits(*names)
        @emits = names.length == 1 ? names.first : names
      end

      # Reference a guard policy by name that must pass before execution.
      #
      # The named policy must be defined on the same aggregate. It is
      # evaluated before the command executes; if it fails, the command
      # is rejected.
      #
      # @param name [String] the guard policy name (e.g. "MustBeAdmin")
      # @return [void]
      def guarded_by(name)
        @guard_name = name
      end

      # Declare a read model this command depends on.
      #
      # Read models document the data this command needs to make decisions.
      # They are used for documentation, event storming visualization, and
      # runtime dependency tracking.
      #
      # @param name [String] the read model name (e.g. "Menu & Availability")
      # @return [void]
      def read_model(name)
        @read_models << Structure::ReadModel.new(name: name)
      end

      # Declare an external system dependency for this command.
      #
      # External systems are third-party services or APIs that the command
      # interacts with. Used for documentation and event storming visualization.
      #
      # @param name [String] the external system name (e.g. "PaymentGateway")
      # @return [void]
      def external(name)
        @external_systems << Structure::ExternalSystem.new(name: name)
      end

      # Declare an actor (role) that may issue this command.
      #
      # Actors represent the users or systems authorized to dispatch this
      # command. Used for documentation, event storming visualization, and
      # port-based access control.
      #
      # @param name [String] the actor/role name (e.g. "Customer", "Admin")
      # @return [void]
      def actor(name)
        @actors << Structure::Actor.new(name: name)
      end

      # Declare static field assignments injected into the aggregate on execution.
      #
      # These key-value pairs are merged into the aggregate's attributes when
      # the command runs, useful for commands that always set certain fields
      # to fixed values (e.g. setting status to "approved").
      #
      # @param hash [Hash{Symbol => Object}] field names mapped to their static values
      # @return [void]
      #
      # @example
      #   sets status: "approved", outcome: "approved"
      def sets(**hash)
        @sets.merge!(hash)
      end

      # Add a precondition that must hold before command execution.
      #
      # Preconditions are checked before the command handler runs. If any
      # precondition fails, the command is rejected with the given message.
      #
      # @param message [String] human-readable description of the precondition
      # @yield block that returns true when the precondition is satisfied
      # @return [void]
      def precondition(message, &block)
        @preconditions << Behavior::Condition.new(message: message, block: block)
      end

      # Add a postcondition that must hold after command execution.
      #
      # Postconditions are checked after the command handler runs. If any
      # postcondition fails, the command's effects are rolled back.
      #
      # @param message [String] human-readable description of the postcondition
      # @yield block that returns true when the postcondition is satisfied
      # @return [void]
      def postcondition(message, &block)
        @postconditions << Behavior::Condition.new(message: message, block: block)
      end

      # Declare a reference to another aggregate.
      #
      # @param type [String] the target aggregate name (e.g. "Team")
      # @param role [String, nil] optional role name, defaults to downcased type
      # @param validate [Boolean, Symbol] validation mode: true (default) checks
      #   existence and authorization; :exists checks existence only; false skips
      #   all validation (opt-out for cross-context eventual consistency)
      # @return [void]
      def reference_to(type, role: nil, validate: true)
        type_str = type.to_s
        parts = type_str.split("::")
        target = parts.last
        domain = parts.length > 1 ? parts[0..-2].join("::") : nil
        name = (role || target.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                               .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase).to_sym
        @references << DomainModel::Structure::Reference.new(
          name: name, type: target, domain: domain, validate: validate
        )
      end

      def ref(type, **opts) = reference_to(type, **opts)

      # Implicit DSL support: `name Type` inside a command block → attribute
      def method_missing(name, *args, **kwargs, &block)
        if args.first.is_a?(Class) || (args.first.is_a?(String) && args.first =~ /\A[A-Z]/)
          attribute(name, args.first, **kwargs)
        elsif args.first.is_a?(Hash) && args.first[:list]
          attribute(name, args.first, **kwargs)
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        true
      end

      # @return [DomainModel::Behavior::Command] the fully built command IR object
      def build
        Behavior::Command.new(
          name: @name, attributes: @attributes, references: @references,
          handler: @handler, guard_name: @guard_name,
          read_models: @read_models, external_systems: @external_systems, actors: @actors,
          call_body: @call_body, sets: @sets,
          preconditions: @preconditions, postconditions: @postconditions,
          emits: @emits, description: @description
        )
      end
    end
  end
end

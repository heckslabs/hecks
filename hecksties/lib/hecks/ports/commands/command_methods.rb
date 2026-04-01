module Hecks
  module Commands
    # Hecks::Commands::CommandMethods
    #
    # Wires command classes to repositories and event buses, then creates
    # shortcut methods on aggregate classes that delegate to command.call.
    # Also binds a .bulk method for composing queries with commands.
    #
    # This module is the bridge between the domain IR (command definitions)
    # and the runtime Ruby classes. During boot, +bind+ iterates over each
    # command in an aggregate, sets up its repository, event bus, handler,
    # guard, and pre/postconditions, then creates convenient shortcut methods
    # so callers can write +Pizza.create(name: "Margherita")+ instead of
    # +PizzasDomain::Pizza::Commands::CreatePizza.call(name: "Margherita")+.
    #
    # == Usage
    #
    #   Commands.bind(PizzaClass, pizza_aggregate, bus, repo, defaults)
    #   Pizza.create(name: "Margherita")  # delegates to CreatePizza.call(...)
    #   Pizza.bulk(:retire, where: { status: "active" })  # batch command
    #
    #   Commands.bind_shortcuts(PizzaClass, pizza_aggregate) { |cmd| executor }
    #   # creates shortcut methods using a custom executor proc
    #
    module CommandMethods
      extend HecksTemplating::NamingHelpers
      # Wires command classes to their repository and event bus, then creates shortcut methods.
      #
      # For each command defined on the aggregate, this method:
      # 1. Auto-includes the Hecks::Command mixin if not already present
      # 2. Sets the repository, event bus, handler, guard, and command bus references
      # 3. Copies pre/postconditions from the domain IR
      # 4. Resolves the event name from the corresponding event definition
      # 5. Creates class-level and instance-level shortcut methods via +bind_shortcuts+
      # 6. Binds the +.bulk+ method via +bind_bulk+
      #
      # @param klass [Class] the aggregate class (e.g., +PizzasDomain::Pizza+)
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the aggregate
      #   definition from the domain IR
      # @param bus [Hecks::Commands::CommandBus] the command bus (used for middleware dispatch
      #   and to access the event bus)
      # @param repo [Object] the repository instance for persisting this aggregate
      # @param defaults [Hash] default attribute values (currently unused but reserved)
      # @return [void]
      def self.bind(klass, aggregate, bus, repo, defaults)
        mod = begin; klass.const_get(:Commands); rescue NameError; nil; end
        return unless mod

        aggregate.commands.each do |cmd|
          cmd_class = begin; mod.const_get(cmd.name); rescue NameError; nil; end
          next unless cmd_class

          # Auto-include mixin if not already included
          cmd_class.include(Hecks::Command) unless cmd_class < Hecks::Command

          # Wire the command to its repository, event bus, handler, and middleware
          cmd_class.repository = repo
          event_bus = bus.respond_to?(:event_bus) ? bus.event_bus : bus
          cmd_class.event_bus = event_bus
          cmd_class.handler = cmd.handler
          cmd_class.guarded_by = cmd.guard_name
          cmd_class.command_bus = bus
          cmd_class.reference_meta = cmd.references if cmd.respond_to?(:references)

          cmd.preconditions.each { |c| cmd_class.preconditions << c }
          cmd.postconditions.each { |c| cmd_class.postconditions << c }

          # Set event name from domain IR (convention: CreatePizza -> CreatedPizza)
          event_idx = aggregate.commands.index { |c| c.name == cmd.name }
          event_def = aggregate.events[event_idx] if event_idx
          cmd_class.emits(event_def.name) if event_def && !cmd_class.event_name
        end

        # Create shortcut methods using cmd_class.call as the executor
        bind_shortcuts(klass, aggregate) do |cmd|
          cmd_class = mod.const_get(cmd.name)
          ->(attrs) { cmd_class.call(**attrs) }
        end

        bind_bulk(klass, aggregate)
      end

      # Adds a +.bulk+ class method that composes queries with commands.
      #
      # The bulk method finds matching aggregates via +where+ or +all+,
      # optionally filters by a specification object, then executes the
      # named command on each match. This is useful for batch operations
      # like retiring all active widgets.
      #
      # @example
      #   Widget.bulk(:retire, where: { status: "active" })
      #   Widget.bulk(:suspend, where: {}, spec: HighRiskSpec)
      #
      # @param klass [Class] the aggregate class to receive the +.bulk+ method
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the aggregate
      #   definition, used to derive the ID field name
      # @return [void]
      def self.bind_bulk(klass, aggregate)
        agg_snake = domain_snake_name(aggregate.name)

        klass.define_singleton_method(:bulk) do |command_method, where: {}, spec: nil|
          items = if where.empty?
            all
          elsif respond_to?(:where)
            self.where(**where).to_a
          else
            all.select do |item|
              where.all? { |k, v| item.respond_to?(k) && item.send(k) == v }
            end
          end
          if spec
            spec_instance = spec.respond_to?(:new) ? spec.new : spec
            items = items.select { |item| spec_instance.satisfied_by?(item) }
          end
          items.map do |item|
            id_field = agg_snake
            send(command_method, **{ id_field.to_sym => item.id })
          end
        end
      end

      # Creates class-level and instance-level shortcut methods on an aggregate class.
      #
      # For each command, derives a shortcut method name by stripping the aggregate
      # name suffix (e.g., +create_pizza+ becomes +create+). Then defines:
      #
      # - A singleton (class) method: +Pizza.create(name: "Margherita")+
      # - An instance method: +pizza.update(name: "New Name")+ that auto-fills
      #   attributes from the instance's own accessors
      #
      # The block must return a callable that accepts a keyword hash and performs
      # the command execution.
      #
      # @param klass [Class] the aggregate class to receive shortcut methods
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the aggregate definition
      # @yield [cmd] called for each command; must return a callable executor
      # @yieldparam cmd [Hecks::DomainModel::Behavior::Command] the command definition
      # @yieldreturn [Proc] a proc that accepts a Hash of attributes and executes the command
      # @return [void]
      def self.bind_shortcuts(klass, aggregate)
        aggregate.commands.each do |cmd|
          executor = yield(cmd)
          method_name = Hecks::Conventions::CommandContract.method_name(cmd.name, aggregate.name)

          # Class method: Pizza.create(name: "Margherita")
          klass.define_singleton_method(method_name) do |**attrs|
            executor.call(attrs)
          end

          # Instance method: cat.meow -- auto-fills from self's attributes
          cmd_attrs = cmd.attributes
          next if klass.method_defined?(method_name)
          klass.define_method(method_name) do |**overrides|
            filled = {}
            cmd_attrs.each do |ca|
              key = ca.name.to_sym
              if overrides.key?(key)
                filled[key] = overrides[key]
              elsif respond_to?(key)
                filled[key] = send(key)
              end
            end
            executor.call(filled)
          end
        end
      end
      end
  end
end

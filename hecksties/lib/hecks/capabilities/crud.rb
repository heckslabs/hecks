# Hecks::Capabilities::Crud
#
# CRUD capability for the hecksagon. Generates Create, Read, Update, and
# Delete command stubs for each aggregate, skipping any command whose name
# the user already defined. Also binds repository methods (.find, .all,
# .create, .update, .delete, .count, .first, .last) via Persistence.
#
# Applied via:
#   runtime.capability(:crud)
#
# User-defined commands always take precedence -- if a "CreatePizza" already
# exists in the Bluebook, the capability will not generate a duplicate.
#
module Hecks
  module Capabilities
    # Hecks::Capabilities::Crud
    #
    # CRUD capability that generates Create/Read/Update/Delete command stubs and binds repository methods.
    #
    module Crud
      extend HecksTemplating::NamingHelpers
      Structure = DomainModel::Structure
      Behavior  = DomainModel::Behavior

      CRUD_PREFIXES = %w[Create Read Update Delete].freeze

      # Apply CRUD to all aggregates in the runtime's domain.
      #
      # @param runtime [Hecks::Runtime] the booted runtime
      # @return [void]
      def self.apply(runtime)
        domain = runtime.domain
        mod_name = HecksTemplating::NamingHelpers.instance_method(:domain_module_name)
          .bind_call(self, domain.name)
        mod = Object.const_get(mod_name)

        domain.aggregates.each do |agg|
          new_commands, new_events = generate_stubs(agg)
          next if new_commands.empty?

          agg.commands.concat(new_commands)
          agg.events.concat(new_events)
          CommandLoader.load(agg, new_commands, new_events, mod_name)
          rewire_aggregate(runtime, agg, mod)
        end
      end

      # Build CRUD command + event IR objects for missing verbs.
      #
      # @param agg [Structure::Aggregate] the aggregate to enrich
      # @return [Array<Array>] [new_commands, new_events]
      def self.generate_stubs(agg)
        existing = agg.commands.map(&:name).to_set
        commands = []
        events   = []

        CRUD_PREFIXES.each do |verb|
          cmd_name = "#{verb}#{agg.name}"
          next if existing.include?(cmd_name)
          next if verb == "Read" # Read is handled by repository, not a command

          cmd_attrs, cmd_refs = attrs_for(verb, agg)
          cmd = Behavior::Command.new(name: cmd_name, attributes: cmd_attrs, references: cmd_refs)
          event = build_event(cmd, agg)
          commands << cmd
          events << event
        end

        [commands, events]
      end

      # Determine attributes and references for a generated CRUD command.
      #
      # @param verb [String] "Create", "Update", or "Delete"
      # @param agg [Structure::Aggregate] the aggregate
      # @return [Array] [attributes, references]
      def self.attrs_for(verb, agg)
        case verb
        when "Create"
          attrs = agg.attributes.reject { |a| reserved?(a.name) }.map do |a|
            Structure::Attribute.new(name: a.name, type: a.type, list: a.list?)
          end
          [attrs, []]
        when "Update"
          snake = HecksTemplating::NamingHelpers.instance_method(:domain_snake_name)
            .bind_call(self, agg.name)
          ref = Structure::Reference.new(name: snake.to_sym, type: agg.name, validate: :exists)
          attrs = agg.attributes.reject { |a| reserved?(a.name) }.map do |a|
            Structure::Attribute.new(name: a.name, type: a.type, list: a.list?)
          end
          [attrs, [ref]]
        when "Delete"
          snake = HecksTemplating::NamingHelpers.instance_method(:domain_snake_name)
            .bind_call(self, agg.name)
          ref = Structure::Reference.new(name: snake.to_sym, type: agg.name, validate: :exists)
          [[], [ref]]
        else
          [[], []]
        end
      end

      # Build a domain event from a command, mirroring AggregateBuilder's inference.
      #
      # @param cmd [Behavior::Command] the command
      # @param agg [Structure::Aggregate] the parent aggregate
      # @return [Behavior::DomainEvent]
      def self.build_event(cmd, agg)
        aggregate_id_attr = Structure::Attribute.new(name: :aggregate_id, type: String)
        event_attrs = [aggregate_id_attr] + cmd.attributes.dup
        agg.attributes.each do |aa|
          next if event_attrs.any? { |ea| ea.name == aa.name }
          event_attrs << aa
        end
        event_refs = cmd.references.dup
        agg.references.each do |ar|
          next if event_refs.any? { |er| er.name == ar.name }
          event_refs << ar
        end
        Behavior::DomainEvent.new(
          name: cmd.event_names.first,
          attributes: event_attrs,
          references: event_refs
        )
      end

      # Load is delegated to CommandLoader (extracted for file size).
      Hecks::Chapters.load_aggregates(
        Hecks::Chapters::Runtime::Setup,
        base_dir: File.expand_path("crud", __dir__)
      )

      # Re-wire command and persistence ports after injecting new commands.
      #
      # @param runtime [Hecks::Runtime] the runtime
      # @param agg [Structure::Aggregate] the aggregate
      # @param mod [Module] the domain module
      # @return [void]
      def self.rewire_aggregate(runtime, agg, mod)
        agg_class = mod.const_get(
          HecksTemplating::NamingHelpers.instance_method(:domain_constant_name)
            .bind_call(self, agg.name)
        )
        repo = runtime[agg.name]
        bus = runtime.command_bus

        defaults = agg.attributes.each_with_object({}) do |attr, h|
          h[attr.name] = attr.list? ? [] : nil
        end

        Commands.bind(agg_class, agg, bus, repo, defaults)
      end

      def self.reserved?(name)
        Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(name.to_s)
      end
      private_class_method :reserved?
    end
  end
end

Hecks.register_capability(:crud) { |runtime| Hecks::Capabilities::Crud.apply(runtime) }

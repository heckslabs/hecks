# Bootstrap: These modules are included at class-body time, so they must
# load before AggregateBuilder is defined. Cannot use chapter-driven loading.
require "hecks/dsl/event_builder"
require "hecks/dsl/projection_builder"
require "hecks/dsl/aggregate_builder/behavior_methods"
require "hecks/dsl/aggregate_builder/constraint_methods"
require "hecks/dsl/aggregate_builder/query_methods"
require "hecks/dsl/aggregate_builder/vo_type_resolution"

module Hecks
  module DSL

    # Hecks::DSL::AggregateBuilder
    #
    # DSL builder for aggregate definitions. Collects attributes, value objects,
    # commands, policies, validations, invariants, scopes, ports, and queries,
    # then builds a BluebookModel::Structure::Aggregate. Automatically infers
    # domain events from commands.
    #
    #   builder = AggregateBuilder.new("Pizza")
    #   builder.attribute :name, String
    #   builder.command("CreatePizza") { attribute :name, String }
    #   builder.scope :large, size: "L"
    #   agg = builder.build
    #
    class AggregateBuilder
      Structure = BluebookModel::Structure
      Behavior  = BluebookModel::Behavior

      include AttributeCollector
      include Describable
      include BehaviorMethods
      include ConstraintMethods
      include QueryMethods

      # Facet registry — add new aggregate facets without modifying this class.
      #
      #   Hecks::DSL::AggregateBuilder.register_facet(:sagas) do |builder|
      #     builder.define_method(:saga) do |name, &block|
      #       @sagas << { name: name, block: block }
      #     end
      #   end
      #
      @facet_registry = {}

      class << self
        attr_reader :facet_registry

        def register_facet(name, &setup)
          @facet_registry[name] = setup
        end
      end

      attr_reader :attributes, :commands, :value_objects, :entities,
                  :policies, :validations, :invariants, :scopes,
                  :queries, :subscribers, :specifications,
                  :references
      # Writer for lifecycle — used by AggregateHandle to update lifecycle
      # without reaching into instance variables. Reader is the DSL method
      # in BehaviorMethods; use current_lifecycle to read.
      attr_writer :lifecycle

      def current_lifecycle
        @lifecycle
      end

      def initialize(name)
        @name = name
        @attributes = []
        @value_objects = []
        @entities = []
        @commands = []
        @policies = []
        @validations = []
        @invariants = []
        @scopes = []
        @queries = []
        @subscribers = []
        @specifications = []
        @references = []
        @explicit_events = []
        @projections = []
        @factories = []
        @computed_attributes = []
        @lifecycle = nil
        @identity_fields = nil
        @metadata = {}
        @facet_data = {}
        @namespace = nil
        @superclass = nil
        @mixins = []
        @crud = false
        self.class.facet_registry.each do |facet_name, setup|
          @facet_data[facet_name] = []
          setup.call(self.class) unless self.class.method_defined?(facet_name)
        end
      end

      # Declare the module namespace this aggregate lives in.
      #   namespace "Hecksagon::DSL"
      def namespace(ns)
        @namespace = ns.to_s
      end

      # Declare the superclass for class-kind aggregates.
      #   inherits "Hecks::Generator"
      def inherits(parent)
        @superclass = parent.to_s
      end

      # Declare a module mixin included by this aggregate.
      #   includes "SqlBuilder"
      #   includes "NamingHelpers"
      def includes(mod_name)
        @mixins << mod_name.to_s
      end

      # Declare a computed (derived) attribute. The block body becomes a
      # method on the generated aggregate class. Not stored in the database.
      #
      #   computed :lot_size do
      #     area / 43560.0
      #   end
      #
      def computed(name, &block)
        @computed_attributes << Structure::ComputedAttribute.new(name: name.to_sym, block: block)
      end

      # Declare a natural key composed from attributes.
      # The UUID always exists — this adds a secondary lookup key.
      #
      #   identity :team, :start_date
      #
      def identity(*fields)
        @identity_fields = fields.map(&:to_sym)
      end

      # Declare a relationship to another type.
      # The kind (composition/aggregation/cross-context) is inferred after build:
      #   reference_to "LineItem"                        — entity/VO → composition
      #   reference_to "Order"                           — aggregate root → aggregation
      #   reference_to "Billing::Invoice"                — cross-domain → cross-context
      #   reference_to "Team", as: :home_team            — canonical alias kwarg
      #   reference_to "Team", role: :home_team          — legacy alias (still works)
      #
      def reference_to(type, as: nil, role: nil)
        raise ArgumentError, "reference_to requires a constant, not a string: #{type.inspect}" if type.class == String
        type_str = type.to_s
        parts = type_str.split("::")
        target = parts.last
        domain = parts.length > 1 ? parts[0..-2].join("::") : nil
        alias_name = as || role
        name = (alias_name || target.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                               .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase).to_sym
        @references << BluebookModel::Structure::Reference.new(
          name: name, type: target, domain: domain
        )
      end

      def ref(type, **opts) = reference_to(type, **opts)

      # Declare a factory for complex aggregate construction.
      #   factory "BuildFromCart" do
      #     attribute :cart_id, String
      #   end
      def factory(name, &block)
        builder = EventBuilder.new(name)  # reuse for attribute collection
        builder.instance_eval(&block) if block
        @factories << { name: name, attributes: builder.build.attributes }
      end

      # Declare an explicit domain event (not inferred from a command).
      # Use for time-based, external, or computed events.
      #
      #   event "PolicyExpired" do
      #     attribute :policy_id, String
      #   end
      #
      def event(name, &block)
        builder = EventBuilder.new(name)
        builder.instance_eval(&block) if block
        @explicit_events << builder.build
      end

      # Define a CQRS read model projection within this aggregate.
      # Projections subscribe to events and maintain denormalized data.
      #
      #   projection "PizzaMenu" do
      #     on "CreatedPizza" do |event|
      #       upsert(event.aggregate_id, name: event.name)
      #     end
      #     query "Popular" do
      #       select { |_id, row| (row[:topping_count] || 0) > 3 }
      #     end
      #   end
      #
      def projection(name, &block)
        builder = ProjectionBuilder.new(name)
        builder.instance_eval(&block) if block
        @projections << builder.build
      end

      # Define a nested value object within this aggregate.
      #
      # @param name [String] the value object type name
      # @yield block evaluated in ValueObjectBuilder context
      # @return [void]
      def value_object(name, &block)
        builder = ValueObjectBuilder.new(name)
        builder.instance_eval(&block) if block
        @value_objects << builder.build
      end

      # Define a nested entity within this aggregate.
      #
      # @param name [String] the entity type name
      # @yield block evaluated in EntityBuilder context
      # @return [void]
      def entity(name, &block)
        builder = EntityBuilder.new(name)
        builder.instance_eval(&block) if block
        @entities << builder.build
      end

      # Declare CRUD commands for this aggregate. Generates Create, Update,
      # and Delete commands from the aggregate's attributes at build time.
      # Skips any verb whose command already exists.
      #
      #   aggregate "Pizza" do
      #     attribute :name, String
      #     crud
      #   end
      #
      def crud
        @crud = true
      end

      # Build the Aggregate IR object, inferring events from commands.
      #
      # @return [BluebookModel::Structure::Aggregate]
      def build
        generate_crud_commands if @crud
        events = merge_events(infer_events, @explicit_events)

        Structure::Aggregate.new(
          name: @name, attributes: @attributes,
          value_objects: @value_objects, entities: @entities,
          commands: @commands, events: events, policies: @policies,
          validations: @validations, invariants: @invariants,
          scopes: @scopes, queries: @queries,
          subscribers: @subscribers,
          specifications: @specifications, computed_attributes: @computed_attributes,
          projections: @projections,
          lifecycle: @lifecycle,
          metadata: @metadata, references: @references,
          factories: @factories, identity_fields: @identity_fields,
          description: @description,
          namespace: @namespace, superclass: @superclass, mixins: @mixins
        )
      end

      private

      def merge_events(inferred, explicit)
        by_name = {}
        inferred.each { |e| by_name[e.name] = e }
        explicit.each { |e| by_name[e.name] = e }
        by_name.values
      end

      def generate_crud_commands
        existing = @commands.map(&:name).to_set
        reserved = Hecks::Utils.respond_to?(:RESERVED_AGGREGATE_ATTRS) ? Hecks::Utils::RESERVED_AGGREGATE_ATTRS : %w[id created_at updated_at]
        user_attrs = @attributes.reject { |a| reserved.include?(a.name.to_s) }

        %w[Create Update Delete].each do |verb|
          cmd_name = "#{verb}#{@name}"
          next if existing.include?(cmd_name)

          cmd_builder = CommandBuilder.new(cmd_name)
          case verb
          when "Create"
            user_attrs.each { |a| cmd_builder.attribute(a.name, a.type) }
            cmd_builder.emits("Created#{@name}")
          when "Update"
            cmd_builder.reference_to(@name)
            user_attrs.each { |a| cmd_builder.attribute(a.name, a.type) }
            cmd_builder.emits("Updated#{@name}")
          when "Delete"
            cmd_builder.reference_to(@name)
            cmd_builder.emits("Deleted#{@name}")
          end
          @commands << cmd_builder.build
        end
      end

      def infer_events
        aggregate_id_attr = Structure::Attribute.new(name: :aggregate_id, type: String)
        @commands.flat_map do |command|
          cmd_attrs = command.attributes.dup
          event_attrs = if cmd_attrs.any? { |a| a.name.to_s == "aggregate_id" }
                          cmd_attrs
                        else
                          [aggregate_id_attr] + cmd_attrs
                        end
          @attributes.each do |agg_attr|
            next if event_attrs.any? { |a| a.name == agg_attr.name }
            event_attrs << agg_attr
          end
          event_refs = command.references.dup
          @references.each do |agg_ref|
            next if event_refs.any? { |r| r.name == agg_ref.name }
            event_refs << agg_ref
          end
          command.event_names.map do |event_name|
            Behavior::BluebookEvent.new(
              name: event_name,
              attributes: event_attrs,
              references: event_refs
            )
          end
        end
      end
    end
  end
end

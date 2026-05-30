# [antibody-exempt: ruby/hecks/dsl/aggregate_builder.rb — kernel-surface
#  Ruby DSL parser ; parity-pair sibling of rust/src/specializer/parser.rs.
#  The bluebook parser cannot be conceived through bluebook (Trikaya floor).
#  Same i147 long-arc retirement contract as the rest of ruby/hecks/dsl/ :
#  retires when the Ruby parser is fully described by
#  hecks_conception/aggregates/language/grammar/*.bluebook plus a generated
#  artifact.]
#
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
                  :references, :views
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
        @views = []
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

      # Declare the natural-key attribute used by storehouse to dispatch
      # commands to a specific aggregate instance. The Rust runtime
      # reads `attrs[identified_by]` ; if no record matches, the value
      # becomes the new record's id. The Ruby DSL accepts the same
      # keyword so the Ruby and Rust parsers stay in parity — both
      # emit `identified_by` into the canonical IR JSON.
      #
      #   identified_by :name
      #
      def identified_by(field)
        @identified_by = field.to_sym
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
          name: name, type: target, domain: domain,
          kind: :reference_to
        )
      end

      def ref(type, **opts) = reference_to(type, **opts)

      # Plural relationship : the aggregate has many of `type`. Plural
      # convention — caller passes the plural form (Stories) ; the target
      # aggregate name is singularized (Story). Attribute name is the
      # snake_case plural ("stories"). Optional arity bounds : `max:` and
      # `at_least:` carry through to Reference#cardinality.
      #
      #   has_many Stories                      # 0..unbounded
      #   has_many Tasks, max: 5                # 0..5
      #   has_many Stories, at_least: 1, max: 5 # 1..5
      def has_many(type, max: nil, at_least: 0, as: nil)
        raise ArgumentError, "has_many requires a constant, not a string: #{type.inspect}" if type.class == String
        plural = type.to_s.split("::").last
        domain = type.to_s.split("::")[0..-2].join("::")
        domain = nil if domain.empty?
        singular = singularize(plural)
        # `as: :alias` overrides the derived snake_case plural so an aggregate
        # can hold multiple collections of the same target type under distinct
        # names (Board has_many Sprints, as: :queued_sprints +
        # has_many Sprints, as: :active_sprints). Mirrors has_one /
        # belongs_to / reference_to and the Rust parser's parse_as_alias.
        attr_name = (as || plural.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                                 .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase).to_sym
        @references << BluebookModel::Structure::Reference.new(
          name: attr_name, type: singular, domain: domain,
          kind: :has_many,
          cardinality: { min: at_least, max: max }
        )
      end

      # Single relationship from owner side. IR-equivalent to belongs_to
      # and reference_to (Cardinality { min: 0, max: 1 }) ; the distinction
      # is intent-only at the bluebook level.
      def has_one(type, as: nil, at_least: 0)
        raise ArgumentError, "has_one requires a constant, not a string: #{type.inspect}" if type.class == String
        target = type.to_s.split("::").last
        domain = type.to_s.split("::")[0..-2].join("::")
        domain = nil if domain.empty?
        attr_name = (as || target.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                                 .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase).to_sym
        @references << BluebookModel::Structure::Reference.new(
          name: attr_name, type: target, domain: domain,
          kind: :has_one,
          cardinality: { min: at_least, max: 1 }
        )
      end

      # Dependent side reference — IR-equivalent to has_one. Strict-Evans
      # warns against denormalizing the parent identity onto the child ;
      # use sparingly, only when the dependent genuinely needs the owner's
      # identity for its own behavior.
      def belongs_to(type, as: nil, at_least: 0)
        raise ArgumentError, "belongs_to requires a constant, not a string: #{type.inspect}" if type.class == String
        target = type.to_s.split("::").last
        domain = type.to_s.split("::")[0..-2].join("::")
        domain = nil if domain.empty?
        attr_name = (as || target.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                                 .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase).to_sym
        @references << BluebookModel::Structure::Reference.new(
          name: attr_name, type: target, domain: domain,
          kind: :belongs_to,
          cardinality: { min: at_least, max: 1 }
        )
      end

      # Simple English singularization : ies → y ; drop trailing s.
      # Irregular plurals (Sheep, Children) round-trip unchanged ;
      # callers may pass the singular form directly when the rule fails.
      private def singularize(plural)
        if plural.end_with?("ies") && plural.length > 3
          "#{plural[0..-4]}y"
        elsif plural.end_with?("s") && plural.length > 1
          plural[0..-2]
        else
          plural
        end
      end

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

      # Declare a named view — a role-scoped projection of this
      # aggregate's fields (i254). Different portals consume the same
      # aggregate through different views ; the view declaration is the
      # single source of truth for "which attributes does this role
      # see". The block accepts `show :a, :b, ...`, `show_all`, and
      # `plus :extras`.
      #
      #   view "for_customer" do
      #     show :scheduled_date, :status, :before_photo, :after_photo, :completed_at
      #   end
      #
      #   view "for_admin" do
      #     show_all
      #     plus :route_id, :worker_account_email, :failed_reason
      #   end
      #
      # @param name [String] the view name (consumed at runtime as
      #   `record.view("for_customer")`)
      # @yield block evaluated in ViewDSL context
      # @return [void]
      def view(name, &block)
        dsl = ViewDSL.new
        dsl.instance_eval(&block) if block
        @views << Structure::View.new(
          name: name, show_all: dsl.show_all_flag, fields: dsl.fields
        )
      end

      # Inner DSL for `view "name" do ... end` blocks. Captures the
      # ordered field list and show_all flag so AggregateBuilder#view
      # can build a Structure::View. Tiny, no-state-leak — one DSL
      # instance per view block.
      class ViewDSL
        attr_reader :fields, :show_all_flag

        def initialize
          @fields = []
          @show_all_flag = false
        end

        def show(*names)
          @fields.concat(names.map(&:to_sym))
        end

        def plus(*names)
          @fields.concat(names.map(&:to_sym))
        end

        def show_all
          @show_all_flag = true
        end
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

      # Accept-and-ignore: legacy nursery bluebooks inline `fixture` calls
      # inside `aggregate` blocks. The canonical location is a sibling
      # `.fixtures` file (see `Hecks.fixtures` DSL). Rust's line-scanner
      # silently skips these — this matches that behavior so parity passes
      # while migration continues. The `io_validator` surfaces stragglers.
      #
      #   aggregate "Pizza" do
      #     fixture "Margherita", name: "Margherita"   # no-op here
      #   end
      def fixture(*_args, **_kwargs, &_block)
        # no-op — canonical home is a `.fixtures` file
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
          namespace: @namespace, superclass: @superclass, mixins: @mixins,
          views: @views
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

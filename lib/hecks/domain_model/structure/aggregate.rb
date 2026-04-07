module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::Aggregate
    #
    # Intermediate representation of a DDD aggregate -- the core building block
    # of a Hecks domain. Groups a root entity with its value objects, commands,
    # events, policies, queries, validations, invariants, scopes, and ports.
    #
    # Built by the DSL layer (AggregateBuilder) and consumed by Generators
    # to produce domain gem source code and persistence adapters.
    #
    #   agg = Aggregate.new(
    #     name: "Pizza",
    #     attributes: [Attribute.new(name: :name, type: String)],
    #     commands: [Command.new(name: "CreatePizza", attributes: [...])],
    #     events: [DomainEvent.new(name: "CreatedPizza", attributes: [...])],
    #     scopes: [Scope.new(name: :active, conditions: { status: "active" })],
    #     ports: { guest: GateDefinition.new(name: :guest, allowed_methods: [:find]) }
    #   )
    #
    class Aggregate
      # @return [String] the PascalCase name of this aggregate (e.g., "Pizza", "Order")
      attr_reader :name

      # @return [Array<Attribute>] the root entity's attributes (typed fields like name, status, etc.)
      attr_reader :attributes

      # @return [Array<ValueObject>] immutable value objects embedded within this aggregate
      attr_reader :value_objects

      # @return [Array<Entity>] mutable sub-entities with identity, owned by this aggregate
      attr_reader :entities

      # @return [Array<Behavior::Command>] commands that mutate this aggregate (e.g., CreatePizza, UpdatePizza)
      attr_reader :commands

      # @return [Array<Behavior::DomainEvent>] domain events emitted by this aggregate's commands
      attr_reader :events

      # @return [Array<Behavior::Policy>] reactive policies triggered by events within this aggregate
      attr_reader :policies

      # @return [Array<Validation>] attribute-level validation rules (presence, type, uniqueness)
      attr_reader :validations

      # @return [Array<Invariant>] business rules that must always hold true for this aggregate
      attr_reader :invariants

      # @return [Array<Scope>] named query scopes for filtering collections of this aggregate
      attr_reader :scopes

      # @return [Hash] empty — ports moved to Hecksagon. Kept for generator compatibility.
      def ports; {}; end

      # @return [Array<Behavior::Query>] named queries defined on this aggregate
      attr_reader :queries

      # @return [Array] event subscribers registered for this aggregate's events
      attr_reader :subscribers

      # @return [Array] specification objects for complex query/filter logic
      attr_reader :specifications

      # @return [Array<Hash>] relationships to other aggregate roots
      attr_reader :references

      # @return [Array<Hash>] factory declarations for complex construction
      attr_reader :factories

      # @return [Array<ComputedAttribute>] derived attributes computed from other attributes
      attr_reader :computed_attributes

      # @return [Lifecycle, nil] optional state machine definition
      attr_reader :lifecycle

      # @return [Array<Symbol>, nil] natural key fields that form the aggregate's
      #   domain-level identity (e.g., [:team, :start_date] for a Season).
      #   This is a domain concept ("this combination of fields uniquely
      #   identifies an instance") — not a persistence index. Persistence layers
      #   may choose to create a unique index from these fields, but that is
      #   an infrastructure decision made outside the domain IR.
      attr_reader :identity_fields

      # Creates a new Aggregate IR node.
      #
      # @param name [String] PascalCase name of the aggregate (e.g., "Pizza")
      # @param attributes [Array<Attribute>] root entity attributes
      # @param value_objects [Array<ValueObject>] embedded value objects
      # @param entities [Array<Entity>] owned sub-entities
      # @param commands [Array<Behavior::Command>] commands that mutate this aggregate
      # @param events [Array<Behavior::DomainEvent>] domain events emitted by commands
      # @param policies [Array<Behavior::Policy>] reactive policies triggered by events
      # @param validations [Array<Validation>] attribute-level validation rules
      # @param invariants [Array<Invariant>] aggregate-level business rules
      # @param scopes [Array<Scope>] named query scopes
      # @param ports [Hash{Symbol => GateDefinition}] access-control port definitions
      # @param queries [Array<Behavior::Query>] named queries
      # @param subscribers [Array] event subscriber registrations
      # @param specifications [Array] specification objects for complex filtering
      # @param lifecycle [Lifecycle, nil] optional state machine definition
      #
      # @return [Aggregate] a new Aggregate instance
      def initialize(name:, attributes: [], value_objects: [], entities: [], commands: [],
                     events: [], policies: [], validations: [], invariants: [],
                     scopes: [], queries: [], subscribers: [],
                     specifications: [], references: [],
                     factories: [], computed_attributes: [],
                     lifecycle: nil, metadata: {}, origin_domain: nil,
                     identity_fields: nil, description: nil,
                     namespace: nil, superclass: nil, mixins: [])
        @name = Names.aggregate_name(name)
        @attributes = attributes
        @value_objects = value_objects
        @entities = entities
        @commands = commands
        @events = events
        @policies = policies
        @validations = validations
        @invariants = invariants
        @scopes = scopes
        @queries = queries
        @subscribers = subscribers
        @specifications = specifications
        @references = references
        @factories = factories
        @computed_attributes = computed_attributes
        @lifecycle = lifecycle
        @metadata = metadata
        @origin_domain = origin_domain
        @identity_fields = identity_fields
        @description = description || @metadata[:description]
        @namespace = namespace
        @superclass = superclass
        @mixins = mixins
      end

      attr_reader :metadata, :origin_domain, :description

      # @return [String, nil] fully qualified namespace (e.g., "Hecksagon::DSL")
      attr_reader :namespace

      # @return [String, nil] superclass for class-kind aggregates (e.g., "Hecks::Generator")
      attr_reader :superclass

      # @return [Array<String>] modules mixed in via include (e.g., ["SqlBuilder", "NamingHelpers"])
      attr_reader :mixins

    end
    end
  end
end

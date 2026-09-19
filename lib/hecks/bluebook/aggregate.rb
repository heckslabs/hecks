require_relative "behaviour/aggregate"
require_relative "expression/ast_json"

module Hecks
  module Bluebook
    # A field read through a `reference_to`, held locally (S12, ADR 0025
    # — "Consistency across aggregate boundaries") — `projects
    # :customer_status, from: :"customer.status"` declares that this
    # aggregate's own `:customer_status` is a copy of the target's own
    # `:status`, kept fresh by a rebuild sweep rather than read live at
    # rule-evaluation time. `reference` names the local reference
    # attribute to walk through (`:customer`, minted by this
    # aggregate's own `reference_to Customer`); `remote_field` names
    # the scalar on the target aggregate to copy.
    ProjectedField = Struct.new(:name, :reference, :remote_field, keyword_init: true)

    # A construct like every other: the aggregate carries its own identity
    # and sits in the owner chain between its chapter (a Bluebook) and
    # everything declared on it. The chain is model objects end to end —
    # reference resolution and hecks_fqn both walk it.
    #
    # The holding half, and nothing else. Every line below restates what
    # `language/bluebook/aggregate.bluebook` already declares — the field
    # list, said again as readers, again as constructor keywords, and
    # again as an emission. That triplication is what a generator removes;
    # `Behaviour::Aggregate` carries everything that is not derivable from
    # the declaration, so regenerating this file can never be lossy.
    #
    # Prototype: hand-written in the shape a generator would emit, to
    # prove the seam before the generator exists. `bin/project_model`
    # would own this file; behaviour/aggregate.rb stays hand-written.
    class Aggregate
      include Construct
      include Hecks::IR
      include Behaviour::Aggregate

      emits_ir(
        name:             :name,
        description:      :description,
        identified_by:    :identity_paths,
        attributes:       many(:attributes),
        value_objects:    many(:value_objects),
        commands:         many(:commands),
        invariants:       -> { invariants.map { |rule| Expression::AstJson.rule_row(rule) } },
        # A precondition shared across commands, declared once (S10, ADR
        # 0025) — the aggregate's own named `given`s, the declaration a
        # referencing command's own (already-resolved) `givens` entry
        # came from. Both sides of "declared once, referenced many"
        # are real IR, the same shape a value object's type and an
        # attribute's own reference to it both are.
        preconditions:    -> { preconditions.map { |rule| Expression::AstJson.rule_row(rule) } },
        # S12, ADR 0025 — deliberately not folded into `attributes`:
        # `EraGuard::ShapeDiff` only ever walks `attributes` to decide
        # whether a new field leaves an existing record with something
        # genuinely absent, and a projected field's own absence story
        # is different — a record predating the `projects` declaration
        # is expected to be missing it until the rebuild sweep runs,
        # not a shape drift a translation needs to explain.
        projected_fields: lambda {
          projected_fields.map do |field|
            { name: field.name.to_s, reference: field.reference.to_s, remote_field: field.remote_field.to_s }
          end
        },
        lifecycle:        one(:lifecycle),
        entities:         many(:entities),
        queries:          many(:queries),
        # Additive — every domain that declares no port emits `ports: []`,
        # the same "regenerate deliberately" wire-format change
        # ir_golden_spec.rb's own header describes; no existing key
        # moves. See docs/decisions (rust/project/ports.rb) for the
        # first reader of this.
        ports:            many(:ports),
        provenance:       :provenance
      )

      attr_reader :name, :description, :attributes, :value_objects, :commands, :invariants, :preconditions,
                  :projected_fields, :identified_by, :identity_paths, :identity_heads, :lifecycle,
                  :entities, :queries, :policies, :ports, :reference_targets, :provenance

      # Assigns what the language declares, then hands off to the
      # behaviour's own `settle` — derived identity, name indexes and
      # owner stamping, none of which the declaration states.
      #
      # @param name [String, Symbol] the aggregate's declared name
      # @param description [String, nil] the aggregate's declared prose description
      # @param attributes [Array<Bluebook::Attribute>] the aggregate's declared fields
      # @param value_objects [Array<Class>] the value object classes (`Bluebook::ValueObject`
      #   subclasses) declared on this aggregate
      # @param commands [Array<Class>] the command classes (`Bluebook::Command` subclasses)
      #   declared on this aggregate
      # @param invariants [Array<Bluebook::Invariant>] the aggregate-level rules that must
      #   always hold
      # @param preconditions [Array<Bluebook::Given>] the aggregate's own named `given`s, a
      #   referencing command's own resolved `givens` entry can point back at
      # @param projected_fields [Array<Bluebook::ProjectedField>] the declared `projects`
      #   fields, copied from another aggregate's own state by the rebuild sweep
      # @param identified_by [String, Symbol, Array<String, Symbol>] the identity path(s)
      #   this aggregate is addressed by
      # @param lifecycle [Bluebook::Lifecycle, nil] the aggregate's declared state machine,
      #   or `nil` if it declares none
      # @param entities [Array<Class>] the entity classes (`Bluebook::Entity` subclasses)
      #   nested directly under this aggregate
      # @param queries [Array<Bluebook::Query>] the queries declared directly on this
      #   aggregate
      # @param policies [Array<Bluebook::Policy>] the reactions hoisted onto this aggregate
      #   from the chapter that assembled it
      # @param ports [Array<Bluebook::DomainPort>] the aggregate-scoped ports attached after
      #   this aggregate was built
      # @param reference_targets [Array<String>] the name of every aggregate this one points
      #   at with an aggregate-level `reference_to`
      # @param provenance [Object, nil] the aggregate's declared canonical source, captured
      #   exactly as written, or `nil` if it declares none
      def initialize(name:, description: nil, attributes: [], value_objects: [],
                     commands: [], invariants: [], preconditions: [], projected_fields: [], identified_by: [], lifecycle: nil,
                     entities: [], queries: [], policies: [], ports: [], reference_targets: [],
                     provenance: nil)
        @name              = name.to_s
        @hecks_name        = @name
        @description       = description
        @attributes        = attributes
        @value_objects     = value_objects
        @commands          = commands
        @invariants        = invariants
        @preconditions     = preconditions
        @projected_fields  = projected_fields
        @identified_by     = identified_by
        @lifecycle         = lifecycle
        @entities          = entities
        @queries           = queries
        @policies          = policies
        @ports             = ports
        @reference_targets = reference_targets
        @provenance        = provenance

        settle
      end
    end
  end
end

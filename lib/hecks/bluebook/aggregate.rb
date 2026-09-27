require_relative "behaviour/aggregate"
require_relative "expression/ast_json"

module Hecks
  module Bluebook
    # A field copied from a `reference_to` target, kept fresh by a rebuild sweep (S12, ADR 0025).
    # `reference` is the local reference attribute to walk; `remote_field` the target's scalar.
    ProjectedField = Struct.new(:name, :reference, :remote_field, keyword_init: true)

    # An aggregate: carries its own identity and sits in the owner chain below its chapter.
    # The holding half only; `Behaviour::Aggregate` carries what the declaration cannot derive.
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
        # The named `given`s a referencing command's resolved `givens` entry came from.
        preconditions:    -> { preconditions.map { |rule| Expression::AstJson.rule_row(rule) } },
        # Not folded into `attributes`: EraGuard::ShapeDiff walks those, and a record predating
        # `projects` is expected to lack this field until the rebuild sweep runs.
        projected_fields: lambda {
          projected_fields.map do |field|
            { name: field.name.to_s, reference: field.reference.to_s, remote_field: field.remote_field.to_s }
          end
        },
        lifecycle:        one(:lifecycle),
        entities:         many(:entities),
        queries:          many(:queries),
        # Additive: domains that declare no port emit `ports: []`; no existing key moves.
        ports:            many(:ports),
        provenance:       :provenance
      )

      attr_reader :name, :description, :attributes, :value_objects, :commands, :invariants, :preconditions,
                  :projected_fields, :identified_by, :identity_paths, :identity_heads, :lifecycle,
                  :entities, :queries, :policies, :ports, :reference_targets, :provenance

      # Assigns the declared fields, then `settle` derives identity, name indexes and owner stamps.
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

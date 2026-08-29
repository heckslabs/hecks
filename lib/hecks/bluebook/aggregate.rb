require_relative "behaviour/aggregate"

module Hecks
  module Bluebook
    # A FIELD READ THROUGH A `reference_to`, HELD LOCALLY (S12, ADR 0025
    # — "Consistency across aggregate boundaries") — `projects
    # :customer_status, from: :"customer.status"` declares that this
    # aggregate's own `:customer_status` is a COPY of the target's own
    # `:status`, kept fresh by a rebuild sweep rather than read live at
    # rule-evaluation time. `reference` names the LOCAL reference
    # attribute to walk through (`:customer`, minted by this
    # aggregate's own `reference_to Customer`); `remote_field` names
    # the SCALAR on the target aggregate to copy.
    ProjectedField = Struct.new(:name, :reference, :remote_field, keyword_init: true)

    # A construct like every other: the aggregate carries its own identity
    # and sits in the owner chain between its chapter (a Bluebook) and
    # everything declared on it. The chain is model objects end to end —
    # reference resolution and hecks_fqn both walk it.
    #
    # THE HOLDING HALF, and nothing else. Every line below restates what
    # `language/bluebook/aggregate.bluebook` already declares — the field
    # list, said again as readers, again as constructor keywords, and
    # again as an emission. That triplication is what a generator removes;
    # `Behaviour::Aggregate` carries everything that is NOT derivable from
    # the declaration, so regenerating this file can never be lossy.
    #
    # PROTOTYPE: hand-written in the shape a generator would emit, to
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
        invariants:       -> { invariants.map { |rule| { description: rule.description, canonical: rule.canonical } } },
        # A PRECONDITION SHARED ACROSS COMMANDS, DECLARED ONCE (S10, ADR
        # 0025) — the aggregate's OWN named `given`s, the declaration a
        # referencing command's own (already-resolved) `givens` entry
        # came from. Both sides of "declared once, referenced many"
        # are real IR, the same shape a value object's TYPE and an
        # attribute's own reference to it both are.
        preconditions:    -> { preconditions.map { |rule| { description: rule.description, canonical: rule.canonical } } },
        # S12, ADR 0025 — deliberately NOT folded into `attributes`:
        # `EraGuard::ShapeDiff` only ever walks `attributes` to decide
        # whether a NEW field leaves an existing record with something
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
        # ADDITIVE — every domain that declares no port emits `ports: []`,
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

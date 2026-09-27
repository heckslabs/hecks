require_relative "behaviour/entity"
require_relative "expression/ast_json"

module Hecks
  module Bluebook
    # An entity as a Ruby class: a piece of an aggregate that has an identity of its own.
    # Not const_set, because a name inside one aggregate can denote more than one kind of thing.
    class Entity
      # Stays interchangeable with an aggregate (`Instance.new(aggregate: entity)`, `CommandRules`
      # `declaring`) but must not answer `value_object`, which `Value.for_attribute` sniffs for.
      extend Construct
      extend Hecks::IR
      extend Behaviour::Entity

      emits_ir(
        name:          :hecks_name,
        description:   :description,
        identified_by: :identity_paths,
        attributes:    many(:attributes),
        commands:      many(:commands),
        queries:       many(:queries),
        entities:      many(:entities),
        # Read-only record of the piece's own `given`; resolved text lands on each command's `givens`.
        preconditions: -> { preconditions.map { |rule| Expression::AstJson.rule_row(rule) } },
        # Checked against every instance of this piece, at the same points as an aggregate's invariants.
        invariants:    -> { invariants.map { |rule| Expression::AstJson.rule_row(rule) } },
        lifecycle:     one(:lifecycle)
      )

      class << self
        attr_reader :description, :identified_by, :identity_paths, :identity_heads,
                    :attributes, :commands, :queries, :entities, :preconditions, :invariants, :lifecycle

        # Mints a new piece class for one declared entity and absorbs its fields into it.
        #
        # @param name [String, Symbol] the entity's declared name
        # @param identified_by [String, Symbol, Array<String, Symbol>, nil] the identity
        #   path(s) this entity is addressed by
        # @param commands [Array<Class>] the command classes declared on this entity
        # @param entities [Array<Class>] the entity classes nested directly under this entity
        # @param lifecycle [Bluebook::Lifecycle, nil] the declared state machine, or `nil`
        # @return [Class] the minted piece class (a `Bluebook::Entity` subclass)
        def declare(name:, description: nil, identified_by: nil, attributes: [],
                    commands: [], queries: [], entities: [], preconditions: [], invariants: [], lifecycle: nil)
          piece = Class.new(self)
          piece.hecks_name = name.to_s
          piece.absorb(description: description, identified_by: identified_by,
                       attributes: attributes, commands: commands,
                       queries: queries, entities: entities, preconditions: preconditions,
                       invariants: invariants, lifecycle: lifecycle)
          piece.stamp_children
          piece
        end

        # Assigns the declared fields, then lets the behaviour's `settle` derive identity and indexes.
        def absorb(description:, identified_by:, attributes:, commands:, queries:, entities:, preconditions:, invariants:,
                   lifecycle:)
          @description    = description
          @identified_by  = identified_by
          @attributes     = attributes
          @commands       = commands
          @queries        = queries
          @entities       = entities
          @preconditions  = preconditions
          @invariants     = invariants
          @lifecycle      = lifecycle

          settle
        end
      end
    end
  end
end

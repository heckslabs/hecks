require_relative "behaviour/entity"
require_relative "expression/ast_json"

module Hecks
  module Bluebook
    # An entity, as a Ruby class — a piece of an aggregate that has an identity
    # of its own.
    #
    # Crossing over closes the owner chain. An entity declares commands, and
    # until now those commands had no owner that could state an identity: an
    # entity was an IR object, not a construct, so `Construct#hecks_fqn` refused
    # rather than answering "Deposit" and looking right. Four of banking's
    # commands were in that state. They can say what they are now —
    # `Banking::Account.Ledger.Deposit` — which is the id the judge already mints
    # for them.
    #
    # Not const_set, for the same reason a command is not: a name inside one
    # aggregate can denote more than one kind of thing, so the constant tree
    # cannot index it.
    #
    # It must stay structurally interchangeable with an aggregate — the runtime
    # builds `Instance.new(aggregate: entity)` and `CommandRules` takes either as
    # `declaring` — so it answers `hecks_name`, `attributes`, `attribute`,
    # `identified_by` and `lifecycle` exactly as an aggregate does. And it must
    # keep not answering `value_object`: `Value.for_attribute` sniffs for that
    # method to tell a piece from a head.
    class Entity
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
        # S17, ADR 0026 — "That is what `entity` is for, and `entity` is
        # declared by the language and used zero times in it" (the ADR's
        # own words). Dispatch nests inside Handler, so an entity's own
        # nested entities are part of its wire shape now, the same way
        # an aggregate's always were — the field the ADR names as
        # declared-but-unused until this slice.
        entities:      many(:entities),
        # ADR 0028 — a piece's own `given`, the same shape
        # `Aggregate#preconditions` already carries (its own `emits_ir`
        # row, identical). A precondition shared across this piece's own
        # commands, declared once — a command references it back by
        # name; the resolved text still lands on each referencing
        # command's own `givens` either way, so this field is read-only
        # documentation of what the piece itself declared, the same
        # relationship `Aggregate.preconditions` already has to its own
        # commands.
        preconditions: -> { preconditions.map { |rule| Expression::AstJson.rule_row(rule) } },
        # A piece's own shape rule, checked against every instance of
        # this piece the aggregate holds (Admissibility#enforce_
        # invariants' own recursive walk) — the same relationship
        # `ValueObject#invariants` already has to its own instances,
        # one level up the construct tree. Not a separate enforcement
        # boundary; still checked at the same two points (after every
        # mutation, before save) the aggregate's own invariants always
        # were — see that method's own comment for why this does not
        # contradict "there is no separate entity invariant."
        invariants:    -> { invariants.map { |rule| Expression::AstJson.rule_row(rule) } },
        lifecycle:     one(:lifecycle)
      )

      class << self
        attr_reader :description, :identified_by, :identity_paths, :identity_heads,
                    :attributes, :commands, :queries, :entities, :preconditions, :invariants, :lifecycle

        # Mints a new piece class for one declared entity and absorbs its fields into it.
        #
        # @param name [String, Symbol] the entity's declared name
        # @param description [String, nil] the entity's declared prose description
        # @param identified_by [String, Symbol, Array<String, Symbol>, nil] the identity
        #   path(s) this entity is addressed by
        # @param attributes [Array<Bluebook::Attribute>] the entity's declared fields
        # @param commands [Array<Class>] the command classes (`Bluebook::Command` subclasses)
        #   declared on this entity
        # @param queries [Array<Bluebook::Query>] the queries declared on this entity
        # @param entities [Array<Class>] the entity classes (`Bluebook::Entity` subclasses)
        #   nested directly under this entity
        # @param preconditions [Array<Bluebook::Given>] this entity's own named `given`s
        # @param invariants [Array<Bluebook::Invariant>] the rules checked against every
        #   instance of this entity
        # @param lifecycle [Bluebook::Lifecycle, nil] the entity's declared state machine,
        #   or `nil` if it declares none
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

        # Assigns what the language declares, then hands off to the
        # behaviour's own `settle` — derived identity and the name
        # indexes, neither of which the declaration states.
        #
        # @param description [String, nil] see `declare`
        # @param identified_by [String, Symbol, Array<String, Symbol>, nil] see `declare`
        # @param attributes [Array<Bluebook::Attribute>] see `declare`
        # @param commands [Array<Class>] see `declare`
        # @param queries [Array<Bluebook::Query>] see `declare`
        # @param entities [Array<Class>] see `declare`
        # @param preconditions [Array<Bluebook::Given>] see `declare`
        # @param invariants [Array<Bluebook::Invariant>] see `declare`
        # @param lifecycle [Bluebook::Lifecycle, nil] see `declare`
        # @return [Class] this piece's own class, self, once identity and indexes are derived
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

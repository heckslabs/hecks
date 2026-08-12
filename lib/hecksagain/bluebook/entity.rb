require_relative "behaviour/entity"

module Hecksagain
  module Bluebook
    # An entity, as a RUBY CLASS — a piece of an aggregate that has an identity
    # of its own.
    #
    # Crossing over closes the OWNER CHAIN. An entity declares commands, and
    # until now those commands had no owner that could state an identity: an
    # entity was an IR object, not a construct, so `Construct#hecks_fqn` refused
    # rather than answering "Deposit" and looking right. Four of banking's
    # commands were in that state. They can say what they are now —
    # `Banking::Account.Ledger.Deposit` — which is the id the judge already mints
    # for them.
    #
    # NOT const_set, for the same reason a command is not: a name inside one
    # aggregate can denote more than one kind of thing, so the constant tree
    # cannot index it.
    #
    # It must stay STRUCTURALLY INTERCHANGEABLE with an aggregate — the runtime
    # builds `Instance.new(aggregate: entity)` and `CommandRules` takes either as
    # `declaring` — so it answers `hecks_name`, `attributes`, `attribute`,
    # `identified_by` and `lifecycle` exactly as an aggregate does. And it must
    # keep NOT answering `value_object`: `Value.for_attribute` sniffs for that
    # method to tell a piece from a head.
    class Entity
      extend Construct
      extend Hecksagain::IR
      extend Behaviour::Entity

      emits_ir(
        name:          :hecks_name,
        description:   :description,
        identified_by: :identity_paths,
        attributes:    many(:attributes),
        commands:      many(:commands),
        queries:       many(:queries),
        lifecycle:     one(:lifecycle)
      )

      class << self
        attr_reader :description, :identified_by, :identity_paths, :identity_heads,
                    :attributes, :commands, :queries, :lifecycle

        def declare(name:, description: nil, identified_by: nil, attributes: [],
                    commands: [], queries: [], lifecycle: nil)
          piece = Class.new(self)
          piece.hecks_name = name.to_s
          piece.absorb(description: description, identified_by: identified_by,
                       attributes: attributes, commands: commands,
                       queries: queries, lifecycle: lifecycle)
          piece.stamp_children
          piece
        end

        # Assigns what the language declares, then hands off to the
        # behaviour's own `settle` — derived identity and the name
        # indexes, neither of which the declaration states.
        def absorb(description:, identified_by:, attributes:, commands:, queries:, lifecycle:)
          @description   = description
          @identified_by = identified_by
          @attributes    = attributes
          @commands      = commands
          @queries       = queries
          @lifecycle     = lifecycle

          settle
        end


      end
    end
  end
end

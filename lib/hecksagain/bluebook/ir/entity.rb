module Hecksagain
  module Bluebook
    module IR
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

        class << self
          attr_reader :description, :identified_by, :attributes, :commands, :queries, :lifecycle

          def declare(name:, description: nil, identified_by: nil, attributes: [],
                      commands: [], queries: [], lifecycle: nil)
            piece = Class.new(self)
            piece.hecks_name = name.to_s
            piece.absorb(description: description, identified_by: identified_by,
                         attributes: attributes, commands: commands,
                         queries: queries, lifecycle: lifecycle)
            # A piece owns the verbs declared on it, so they can state an identity.
            commands.each { |verb| verb.hecks_owner = piece }
            piece
          end

          def absorb(description:, identified_by:, attributes:, commands:, queries:, lifecycle:)
            @description   = description
            @identified_by = identified_by
            @attributes    = attributes
            @commands      = commands
            @queries       = queries
            @lifecycle     = lifecycle
          end

          def attribute(named) = attributes.find { |held| held.name == named.to_sym }
          def command(named)   = commands.find { |verb| verb.hecks_name == named.to_s }
          def query(named)     = queries.find { |ask| ask.hecks_name == named.to_s }

          def to_h
            {
              name:          hecks_name,
              description:   description,
              identified_by: identified_by&.to_s,
              attributes:    attributes.map(&:to_h),
              commands:      commands.map(&:to_h),
              queries:       queries.map(&:to_h),
              lifecycle:     lifecycle&.to_h
            }
          end
        end
      end
    end
  end
end

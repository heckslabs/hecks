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
        extend Hecksagain::IR

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
            # A piece owns the verbs declared on it, so they can state an identity.
            commands.each { |verb| verb.hecks_owner = piece }
            queries.each  { |ask|  ask.hecks_owner  = piece }
            piece
          end

          def absorb(description:, identified_by:, attributes:, commands:, queries:, lifecycle:)
            @description   = description
            # Split exactly as an aggregate splits it, several paths included. The
            # PATH "sequence.value" says which field carries the identity ;
            # `identity_heads` are the attributes those paths start at, because
            # every reader that looks up or coerces an attribute — the element
            # finder, the sort key, the identity an appended piece is given —
            # wants the attribute, not the path. `identified_by` is the single
            # head, offered only when there is one path to have a head of.
            @identity_paths = Array(identified_by).map { |path| path.to_s }.reject(&:empty?)
            @identity_heads = @identity_paths.map { |path| path.split(".").first.to_sym }
            @identified_by  = @identity_heads.size == 1 ? @identity_heads.first : nil
            @attributes    = attributes
            @commands      = commands
            @queries       = queries
            @lifecycle     = lifecycle
            # Indexed once — attributes/commands/queries are final once absorbed,
            # and every dispatch asks these finders by name.
            @attributes_by_name = attributes.to_h { |held| [held.name, held] }
            @commands_by_name   = commands.to_h { |verb| [verb.hecks_name, verb] }
            @queries_by_name    = queries.to_h { |ask| [ask.hecks_name, ask] }
          end

          def attribute(named) = @attributes_by_name[named.to_sym]
          def command(named)   = @commands_by_name[named.to_s]
          def query(named)     = @queries_by_name[named.to_s]

        end
      end
    end
  end
end

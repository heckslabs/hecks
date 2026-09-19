module Hecks
  module Bluebook
    module Behaviour
      # The behaviour more than one construct shares.
      #
      # None of this is new duplication. `attribute(named)` was written
      # out four separate times — on Aggregate, Entity, Command and
      # PortOperation — and the identity derivation twice, byte for byte,
      # for as long as those constructs have existed. Splitting holding
      # from doing is what made them visible: the same method in four
      # files reads as four methods, and the same method in four modules
      # named `Behaviour::*` reads as one repeated.
      #
      # Written to work whether the construct is included into (an
      # ordinary object like Aggregate) or extended into (a class-shaped
      # one like Command), because every one of them reads instance
      # variables and nothing else.

      # A construct whose identity is a join of declared paths.
      #
      # The paths, in declaration order, because the identity is their join.
      # "number.value" says which field carries the identity ; several paths
      # say the identity is made of several facts, which is what anything
      # named beneath another thing needs. `identity_heads` are the attributes
      # those paths start at — what every reader that looks up or coerces an
      # attribute actually wants — and `identified_by` is the single head,
      # offered only when there is one path to have a head of. A composite has
      # no single head, and answering with the first would be a guess ; the
      # readers that need all of them ask for `identity_heads`.
      module Identified
        # Derives `identity_paths`, `identity_heads` and the single-head form of
        # `identified_by` from the declared `identified_by` path(s).
        #
        # @return [void]
        def derive_identity
          @identity_paths = Array(@identified_by).map(&:to_s).reject(&:empty?)
          @identity_heads = @identity_paths.map { |path| path.split(".").first.to_sym }.uniq
          @identified_by  = @identity_heads.size == 1 ? @identity_heads.first : nil
        end
      end

      # A construct that answers for its own declarations by name.
      #
      # Indexed once, since the declarations are final by the time the
      # construct exists — every dispatch asks these finders by name, and a
      # linear scan repeated on every call was doing work the declared shape
      # had already settled at boot.
      #
      # `index_by_name` takes the collections to index rather than naming
      # them, because which collections a construct has is exactly the part
      # that differs: an aggregate has five, an entity three, a command one.
      module Indexed
        # Keyed by symbol — an attribute is asked for by its declared
        # symbol name everywhere in the runtime.
        #
        # @param attributes [Array<Bluebook::Attribute>] the construct's declared
        #   attributes
        # @return [void]
        def index_attributes(attributes)
          @attributes_by_name = attributes.to_h { |held| [held.name, held] }
        end

        # Keyed by string and by `hecks_name` — a command, query or value
        # object is a construct whose Ruby `name` is something else
        # entirely (a constant path, or nothing at all for an anonymous
        # class), so the declared name is the only one worth indexing.
        #
        # @param collection [Array<#hecks_name>] declared constructs to index —
        #   value objects, commands or queries, each answering `hecks_name`
        # @return [Hash{String => Object}] the collection keyed by each member's
        #   `hecks_name`
        def index_by_hecks_name(collection)
          collection.to_h { |held| [held.hecks_name, held] }
        end

        # Finds a declared attribute by its declared name.
        #
        # @param named [String, Symbol] the attribute's declared name
        # @return [Bluebook::Attribute, nil] the attribute named `named`, or `nil`
        #   if none is declared under that name
        def attribute(named) = @attributes_by_name[named.to_sym]

        # Finds a declared command by its declared name.
        #
        # @param named [String, Symbol] the command's declared name
        # @return [Class, nil] the command class (a `Bluebook::Command` subclass)
        #   named `named`, or `nil` if none is declared under that name
        def command(named)   = @commands_by_name[named.to_s]

        # Finds a declared query by its declared name.
        #
        # @param named [String, Symbol] the query's declared name
        # @return [Bluebook::Query, nil] the query named `named`, or `nil` if none
        #   is declared under that name
        def query(named)     = @queries_by_name[named.to_s]
      end

      # A construct that owns what it declares.
      #
      # Owner links are only ever read lazily — hecks_fqn at ask time,
      # Reference#resolve at dispatch time — so the moment the construct
      # is complete is the right stamping point: its declarations are
      # final, and nothing outside needs to remember to stamp them.
      module Owns
        # Stamps each of `children` as owned by this construct.
        #
        # @param children [Array<Object>] the construct's own declared children —
        #   arrays or bare objects, flattened before stamping — each answering
        #   `hecks_owner=`
        # @return [void]
        def stamp(*children)
          children.flatten.each { |child| child.hecks_owner = self }
        end
      end
    end
  end
end

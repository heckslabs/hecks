module Hecks
  module Bluebook
    module Behaviour
      # Behaviour shared by more than one construct. Each module works whether it is included
      # (an ordinary object like Aggregate) or extended (a class-shaped one like Command),
      # because it reads only instance variables.

      # A construct whose identity is a join of declared paths.
      #
      # Several paths mean the identity is made of several facts. `identity_heads` are the
      # attributes those paths start at; `identified_by` is the single head, set only when there
      # is exactly one, since a composite has no single head and the first would be a guess.
      module Identified
        # Derives `identity_paths`, `identity_heads` and the single-head `identified_by`.
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
      # Indexed once because declarations are final when the construct exists. `index_by_name`
      # takes the collections to index since which ones a construct has differs per construct.
      module Indexed
        # Keyed by symbol, the way the runtime asks for an attribute.
        #
        # @param attributes [Array<Bluebook::Attribute>]
        # @return [void]
        def index_attributes(attributes)
          @attributes_by_name = attributes.to_h { |held| [held.name, held] }
        end

        # Keyed by string and by `hecks_name`, since such a construct's Ruby `name` is a
        # constant path or nothing at all for an anonymous class.
        #
        # @param collection [Array<#hecks_name>] value objects, commands or queries
        # @return [Hash{String => Object}]
        def index_by_hecks_name(collection)
          collection.to_h { |held| [held.hecks_name, held] }
        end

        # Finds a declared attribute by name.
        #
        # @param named [String, Symbol]
        # @return [Bluebook::Attribute, nil]
        def attribute(named) = @attributes_by_name[named.to_sym]

        # Finds a declared command by name.
        #
        # @param named [String, Symbol]
        # @return [Class, nil] a `Bluebook::Command` subclass
        def command(named)   = @commands_by_name[named.to_s]

        # Finds a declared query by name.
        #
        # @param named [String, Symbol]
        # @return [Bluebook::Query, nil]
        def query(named)     = @queries_by_name[named.to_s]
      end

      # A construct that owns what it declares.
      #
      # Owner links are read lazily (hecks_fqn, Reference#resolve), so stamping when the
      # construct is complete is early enough and needs no help from outside.
      module Owns
        # Stamps each of `children` as owned by this construct.
        #
        # @param children [Array<#hecks_owner=>] arrays or bare objects, flattened first
        # @return [void]
        def stamp(*children)
          children.flatten.each { |child| child.hecks_owner = self }
        end
      end
    end
  end
end

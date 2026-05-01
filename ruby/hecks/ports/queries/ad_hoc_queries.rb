module Hecks
  module Querying
    # Hecks::Querying::AdHocQueries
    #
    # Opt-in mixin that provides ActiveRecord-style query methods (where,
    # find_by, first, last, order, limit, offset) on aggregate classes.
    # All repository references are closure-captured for per-application isolation,
    # meaning each booted application gets its own repository binding.
    #
    # These methods are the primary entry points for querying aggregates.
    # Each returns a QueryBuilder instance (except find_by, which returns
    # a single record or nil), enabling method chaining.
    #
    # == Usage
    #
    #   Hecks::Querying::AdHocQueries.bind(Pizza, repo)
    #
    #   Pizza.where(style: "Classic").order(:name).limit(5)
    #   Pizza.order(:name).limit(5)
    #   Pizza.limit(10).offset(20)
    #   Pizza.find_by(name: "Margherita")  # => single Pizza or nil
    #
    module AdHocQueries
      # Binds query class methods onto an aggregate class.
      #
      # Stores the repository reference on the class and defines singleton
      # methods that create fresh QueryBuilder instances scoped to that repository.
      # This ensures each aggregate class is bound to its own repository.
      #
      # @param klass [Class] the aggregate class to receive query methods
      #   (e.g., +PizzasDomain::Pizza+)
      # @param repo [Object] the repository instance for this aggregate;
      #   must respond to +#all+ and optionally +#query+
      # @return [void]
      def self.bind(klass, repo)
        klass.instance_variable_set(:@__hecks_repo__, repo)

        # Defines +.where+ -- returns a QueryBuilder filtered by the given conditions.
        # @param conditions [Hash] attribute-value pairs to filter by
        # @return [Hecks::Querying::QueryBuilder] a chainable query
        klass.define_singleton_method(:where) do |**conditions|
          Querying::QueryBuilder.new(repo).where(**conditions)
        end

        # Defines +.find_by+ -- returns the first record matching conditions, or nil.
        # @param conditions [Hash] attribute-value pairs to match
        # @return [Object, nil] the first matching aggregate instance or nil
        klass.define_singleton_method(:find_by) do |**conditions|
          Querying::QueryBuilder.new(repo).find_by(**conditions)
        end

        # Defines +.order+ -- returns a QueryBuilder sorted by the given key.
        # @param key_or_hash [Symbol, Hash] sort key or {key: :desc} hash
        # @return [Hecks::Querying::QueryBuilder] a chainable query
        klass.define_singleton_method(:order) do |key_or_hash|
          Querying::QueryBuilder.new(repo).order(key_or_hash)
        end

        # Defines +.limit+ -- returns a QueryBuilder limited to n results.
        # @param n [Integer] maximum number of results
        # @return [Hecks::Querying::QueryBuilder] a chainable query
        klass.define_singleton_method(:limit) do |n|
          Querying::QueryBuilder.new(repo).limit(n)
        end

        # Defines +.offset+ -- returns a QueryBuilder that skips the first n results.
        # @param n [Integer] number of results to skip
        # @return [Hecks::Querying::QueryBuilder] a chainable query
        klass.define_singleton_method(:offset) do |n|
          Querying::QueryBuilder.new(repo).offset(n)
        end
      end
      end
  end
end

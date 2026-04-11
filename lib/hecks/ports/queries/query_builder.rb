Hecks::Chapters.load_aggregates(
  Hecks::Runtime::PortInternals,
  base_dir: __dir__
)
Hecks::Chapters.load_aggregates(
  Hecks::Runtime::PortInternals,
  base_dir: File.expand_path("query_builder", __dir__)
)

module Hecks
  module Querying
    # Hecks::Querying::QueryBuilder
    #
    # Chainable query interface for aggregate repositories. Collects query
    # parameters (conditions, ordering, limit, offset) and delegates execution
    # to the adapter's +query+ method when possible, falling back to in-memory
    # filtering via InMemoryExecutor for complex conditions or simple adapters.
    #
    # QueryBuilder is immutable-by-convention: every chaining method (+where+,
    # +order+, +limit+, +offset+, +or+) returns a new QueryBuilder via +dup+,
    # leaving the original unchanged. This makes it safe to store and reuse
    # intermediate queries.
    #
    # Includes Enumerable, so all standard Ruby collection methods (map, select,
    # reduce, etc.) work on query results.
    #
    # == Condition Composition
    #
    # Conditions are stored as a ConditionNode tree. +where+ adds AND conditions;
    # +or+ combines two queries with OR logic. Operator objects (Gt, Lt, In, etc.)
    # can be used as values for non-equality comparisons.
    #
    # == Usage
    #
    #   Pizza.where(style: "Classic").order(:name).limit(5)
    #   Pizza.where(style: "Classic").or(Pizza.where(style: "Tropical"))
    #   Pizza.find_by(name: "Margherita")
    #   Pizza.where(price: Operators::Gt.new(10)).pluck(:name)
    #
    class QueryBuilder
      include Enumerable
      include InMemoryExecutor

      # Initializes a blank query against the given repository.
      #
      # @param repo [Object] the repository to query; must respond to +#all+
      #   and optionally +#query+ for adapter-native queries
      def initialize(repo)
        @repo = repo
        @condition_tree = ConditionNode.and
        @order_key = nil
        @order_direction = :asc
        @limit_value = nil
        @offset_value = nil
      end

      # --- Chaining ---

      # Returns a new query scoped by the given attribute conditions (AND logic).
      #
      # @param conditions [Hash<Symbol, Object>] attribute-value pairs; values can be
      #   literals (equality) or Operator instances (Gt, Lt, In, etc.)
      # @return [QueryBuilder] a new query with the additional conditions merged in
      def where(**conditions)
        dup.tap { |query| query.instance_variable_set(:@condition_tree, query.instance_variable_get(:@condition_tree).merge(conditions)) }
      end

      # Combines this query with another using OR logic.
      #
      # Returns a new query whose condition tree is an OR node containing
      # both this query's conditions and the other query's conditions.
      #
      # @param other [QueryBuilder] another query to OR with
      # @return [QueryBuilder] a new query matching either this OR other
      def or(other)
        dup.tap do |query|
          combined = ConditionNode.or(
            query.instance_variable_get(:@condition_tree),
            other.instance_variable_get(:@condition_tree)
          )
          query.instance_variable_set(:@condition_tree, combined)
        end
      end

      # Returns a new query sorted by the given key or {key: direction} hash.
      #
      # @param key_or_hash [Symbol, Hash<Symbol, Symbol>] either a sort key
      #   (ascending by default) or a hash like +{ name: :desc }+
      # @return [QueryBuilder] a new query with the specified ordering
      def order(key_or_hash)
        dup.tap do |query|
          if key_or_hash.is_a?(Hash)
            key = key_or_hash.keys.first
            dir = key_or_hash.values.first
            query.instance_variable_set(:@order_key, key)
            query.instance_variable_set(:@order_direction, dir)
          else
            query.instance_variable_set(:@order_key, key_or_hash)
            query.instance_variable_set(:@order_direction, :asc)
          end
        end
      end

      # Returns a new query limited to at most +n+ results.
      #
      # @param n [Integer] maximum number of results to return
      # @return [QueryBuilder] a new query with the limit applied
      def limit(n)
        dup.tap { |query| query.instance_variable_set(:@limit_value, n) }
      end

      # Returns a new query that skips the first +n+ results.
      #
      # @param n [Integer] number of results to skip
      # @return [QueryBuilder] a new query with the offset applied
      def offset(n)
        dup.tap { |query| query.instance_variable_set(:@offset_value, n) }
      end

      # --- Terminals ---

      # Returns the first record matching the given conditions, or nil.
      #
      # @param conditions [Hash<Symbol, Object>] attribute-value pairs to filter by
      # @return [Object, nil] the first matching aggregate instance or nil
      def find_by(**conditions) = where(**conditions).first

      # Returns the first result from the query.
      # @return [Object, nil] the first matching record or nil if empty
      def first   = execute.first

      # Returns the last result from the query.
      # @return [Object, nil] the last matching record or nil if empty
      def last    = execute.last

      # Returns the number of matching records.
      # @return [Integer] the count of results
      def count   = execute.size

      # Executes the query and returns results as an Array.
      # @return [Array<Object>] all matching aggregate instances
      def to_a    = execute

      # Iterates over each matching record. Required by Enumerable.
      # @yield [obj] called once for each matching record
      # @yieldparam obj [Object] a matching aggregate instance
      # @return [Enumerator, void] an enumerator if no block given
      def each(&block) = execute.each(&block)

      # Returns true if no records match the query.
      # @return [Boolean] true when the result set is empty
      def empty?  = execute.empty?

      # Returns true if at least one record matches the query.
      # @return [Boolean] true when at least one result exists
      def exists? = !execute.empty?

      # Returns the number of matching records. Alias for #count.
      # @return [Integer] the count of results
      def size    = count
      alias length size

      # Extracts one or more attribute values from each matching record.
      #
      # With a single key, returns a flat array of values.
      # With multiple keys, returns an array of arrays.
      #
      # @param keys [Array<Symbol>] one or more attribute names to extract
      # @return [Array<Object>, Array<Array<Object>>] extracted values
      def pluck(*keys)
        rows = execute
        keys.size == 1 ? rows.map { |record| record.send(keys.first) } : rows.map { |record| keys.map { |attr_key| record.send(attr_key) } }
      end

      # Returns the sum of the given attribute across matching records.
      # Nil values are excluded.
      #
      # @param key [Symbol] the attribute to sum
      # @return [Numeric] the sum, or 0 if no non-nil values
      def sum(key)     = execute.map { |record| record.send(key) }.compact.sum

      # Returns the minimum value of the given attribute across matching records.
      # Nil values are excluded.
      #
      # @param key [Symbol] the attribute to find the minimum of
      # @return [Comparable, nil] the minimum value, or nil if no results
      def min(key)     = execute.map { |record| record.send(key) }.compact.min

      # Returns the maximum value of the given attribute across matching records.
      # Nil values are excluded.
      #
      # @param key [Symbol] the attribute to find the maximum of
      # @return [Comparable, nil] the maximum value, or nil if no results
      def max(key)     = execute.map { |record| record.send(key) }.compact.max

      # Returns the arithmetic mean of the given attribute, or nil if empty.
      # Nil values are excluded before computing the average.
      #
      # @param key [Symbol] the attribute to average
      # @return [Float, nil] the arithmetic mean, or nil if no non-nil values
      def average(key)
        vals = execute.map { |record| record.send(key) }.compact
        vals.empty? ? nil : vals.sum.to_f / vals.size
      end

      # Bulk deletes all matching records from the repository.
      #
      # WARNING: Bypasses the command bus -- no domain events are fired.
      # Use only for administrative or cleanup operations.
      #
      # @return [void]
      def delete_all
        execute.each { |obj| @repo.delete(obj.id) }
      end

      # Bulk updates all matching records with the given attributes.
      #
      # Reconstructs each object with merged attributes and saves it.
      # WARNING: Bypasses the command bus -- no domain events are fired.
      # Use only for administrative or cleanup operations.
      #
      # @param attrs [Hash<Symbol, Object>] attribute values to set on each record
      # @return [void]
      def update_all(**attrs)
        execute.each do |obj|
          init_params = obj.class.instance_method(:initialize).parameters.map { |_, param_name| param_name }
          current = init_params.each_with_object({}) { |param, hash| hash[param] = obj.send(param) if obj.respond_to?(param) }
          updated = obj.class.new(**current.merge(attrs))
          @repo.save(updated)
        end
      end

      # --- Operators ---

      # Creates a greater-than operator for use in where conditions.
      # @param value [Comparable] the threshold value
      # @return [Operators::Gt] the operator instance
      def gt(value)     = Operators::Gt.new(value)

      # Creates a greater-than-or-equal operator for use in where conditions.
      # @param value [Comparable] the threshold value
      # @return [Operators::Gte] the operator instance
      def gte(value)    = Operators::Gte.new(value)

      # Creates a less-than operator for use in where conditions.
      # @param value [Comparable] the threshold value
      # @return [Operators::Lt] the operator instance
      def lt(value)     = Operators::Lt.new(value)

      # Creates a less-than-or-equal operator for use in where conditions.
      # @param value [Comparable] the threshold value
      # @return [Operators::Lte] the operator instance
      def lte(value)    = Operators::Lte.new(value)

      # Creates a not-equal operator for use in where conditions.
      # @param value [Object] the value to exclude
      # @return [Operators::NotEq] the operator instance
      def not_eq(value) = Operators::NotEq.new(value)

      # Creates an inclusion operator for use in where conditions.
      # @param values [Array] the allowed values
      # @return [Operators::In] the operator instance
      def one_of(values) = Operators::In.new(values)

      # Returns a human-readable summary of the query state for debugging.
      # @return [String] inspection string showing condition tree type, order, and limit
      def inspect
        "#<Hecks::QueryBuilder condition_tree=#{@condition_tree.type} order=#{@order_key} limit=#{@limit_value}>"
      end

      private

      # Executes the query, choosing between adapter-native and in-memory strategies.
      #
      # For simple AND conditions (no children, no OR), delegates to the adapter's
      # +#query+ method if available. Otherwise falls back to in-memory filtering
      # via InMemoryExecutor.
      #
      # @return [Array<Object>] the filtered, sorted, and paginated results
      def execute
        # For simple AND conditions, use the adapter's native query method
        if @condition_tree.simple? && @repo.respond_to?(:query)
          @repo.query(
            conditions: @condition_tree.conditions,
            order_key: @order_key,
            order_direction: @order_direction,
            limit: @limit_value,
            offset: @offset_value
          )
        else
          in_memory_execute
        end
      end
      end
  end
end

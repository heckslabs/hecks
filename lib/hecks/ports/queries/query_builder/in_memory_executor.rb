module Hecks
  module Querying
    class QueryBuilder
        # Hecks::Querying::QueryBuilder::InMemoryExecutor
        #
        # Fallback query engine for adapters without native query support,
        # or when conditions include OR nodes that cannot be translated to
        # adapter-specific expressions. Filters using the ConditionNode tree,
        # then sorts, offsets, and limits results entirely in Ruby.
        #
        # This module is included into QueryBuilder and invoked when:
        # - The repository does not respond to +#query+
        # - The condition tree is not simple (contains OR nodes or nested children)
        #
        # == Processing Pipeline
        #
        # 1. Fetch all records from the repository via +@repo.all+
        # 2. Filter by condition tree (+apply_conditions+)
        # 3. Sort by order key and direction (+apply_order+)
        # 4. Skip records by offset (+apply_offset+)
        # 5. Limit result count (+apply_limit+)
        #
        # == Usage
        #
        #   # Used internally by QueryBuilder#execute:
        #   #   in_memory_execute  # => filtered, sorted, paginated Array
        #
        module InMemoryExecutor
          private

          # Executes the full in-memory query pipeline.
          #
          # Fetches all records from the repository, then applies conditions,
          # ordering, offset, and limit in sequence.
          #
          # @return [Array<Object>] the filtered, sorted, and paginated results
          def in_memory_execute
            results = @repo.respond_to?(:all) ? @repo.all : []
            results = apply_conditions(results)
            results = apply_order(results)
            results = apply_offset(results)
            results = apply_limit(results)
            results
          end

          # Filters results using the condition tree.
          #
          # Returns all records unchanged if the condition tree is empty
          # (no conditions and no children). Otherwise delegates to
          # +ConditionNode#match?+ for each record.
          #
          # @param results [Array<Object>] the records to filter
          # @return [Array<Object>] records that match the condition tree
          def apply_conditions(results)
            return results if @condition_tree.conditions.empty? && @condition_tree.children.empty?

            results.select { |obj| @condition_tree.match?(obj) }
          end

          # Sorts results by the configured order key and direction.
          #
          # Returns results unchanged if no order key is set. Nil values
          # are sorted as empty strings to avoid comparison errors.
          #
          # @param results [Array<Object>] the records to sort
          # @return [Array<Object>] sorted records; reversed if direction is +:desc+
          def apply_order(results)
            return results unless @order_key

            sorted = results.sort_by do |obj|
              val = obj.respond_to?(@order_key) ? obj.send(@order_key) : nil
              val.nil? ? "" : val
            end

            @order_direction == :desc ? sorted.reverse : sorted
          end

          # Skips the first N results based on the configured offset.
          #
          # @param results [Array<Object>] the records to offset
          # @return [Array<Object>] records with the first @offset_value entries dropped
          def apply_offset(results)
            return results unless @offset_value
            results.drop([@offset_value, 0].max)
          end

          # Limits results to at most N records based on the configured limit.
          #
          # @param results [Array<Object>] the records to limit
          # @return [Array<Object>] at most @limit_value records
          def apply_limit(results)
            return results unless @limit_value
            results.take([@limit_value, 0].max)
          end
        end
      end
  end
end

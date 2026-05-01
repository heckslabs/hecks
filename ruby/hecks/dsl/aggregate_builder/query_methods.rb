# Hecks::DSL::AggregateBuilder::QueryMethods
#
# Scope and query DSL methods extracted from AggregateBuilder.
#
module Hecks
  module DSL
    class AggregateBuilder
      module QueryMethods
        # Define a named query scope with conditions or a lambda.
        #
        # @param name [Symbol] the scope name
        # @param conditions_or_lambda [Hash, Proc, nil] filter conditions
        # @yield optional block used as conditions
        # @return [void]
        def scope(name, conditions_or_lambda = nil, &block)
          conditions = block || conditions_or_lambda
          @scopes << BluebookModel::Structure::Scope.new(name: name, conditions: conditions)
        end

        # Define a custom query with a block.
        #
        # @param name [Symbol] the query name
        # @yield block implementing the query logic
        # @return [void]
        def query(name, &block)
          @queries << BluebookModel::Behavior::Query.new(name: name, block: block)
        end
      end
    end
  end
end

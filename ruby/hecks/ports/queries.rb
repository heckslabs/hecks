  # Hecks::Querying
  #
  # Groups all query-related services: the chainable QueryBuilder,
  # AdHocQueries, ScopeMethods, and comparison Operators.
  #
  # This module is the query-side counterpart to Hecks::Commands. It provides
  # a composable, chainable query interface that works with any repository
  # adapter (in-memory, SQL, etc.).
  #
  # == Components
  #
  # - QueryBuilder -- chainable query interface with where/order/limit/offset
  # - AdHocQueries -- binds where/find_by/order/limit/offset as class methods
  # - ScopeMethods -- binds named scopes from the DSL as class methods
  # - Operators -- comparison wrappers (Gt, Lt, In, etc.) for advanced conditions
  # - ConditionNode -- tree structure for composing AND/OR conditions
  # - CrossDomainQuery -- read-only queries that span multiple bounded contexts
  #
  # == Usage
  #
  # Querying.bind wires named scopes onto aggregate classes. AdHocQueries
  # (where, find_by, order, limit) is bound separately by Application
  # during repository setup.
  #
  #   Querying.bind(agg_class, aggregate)
  #   # Now Pizza.classics returns a QueryBuilder scoped to classic pizzas
  #
module Hecks
  # Hecks::Querying
  #
  # Groups all query services: chainable QueryBuilder, AdHocQueries, ScopeMethods, and Operators.
  #
  module Querying
      autoload :QueryBuilder,  "hecks/ports/queries/query_builder"
      autoload :AdHocQueries,  "hecks/ports/queries/ad_hoc_queries"
      autoload :ScopeMethods,  "hecks/ports/queries/scope_methods"
      autoload :Operators,     "hecks/ports/queries/operators"

      # Wires named scopes from the aggregate definition onto the class.
      #
      # Delegates to ScopeMethods.bind, which reads scope definitions from the
      # domain IR and creates corresponding singleton methods on the aggregate class.
      #
      # @param klass [Class] the aggregate class to receive scope methods
      # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
      #   definition containing scope metadata
      # @return [void]
      def self.bind(klass, aggregate)
        ScopeMethods.bind(klass, aggregate)
      end
  end
end

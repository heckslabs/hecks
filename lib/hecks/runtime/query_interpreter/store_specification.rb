module Hecks
  module Runtime
    class QueryInterpreter
      # The form of a declared query a store answers itself: its arguments normalized, the
      # tenant scope and reference hops applied, as `#call` hands it to the store's native hook.
      module StoreSpecification
        # The specification and arguments the store would answer a query with, or nil when an
        # outside port, a plugin or an entity answers it instead.
        #
        # @param domain [String] the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate declaring the query
        # @param query_name [String] the query's declared name
        # @param args [Hash{Symbol => Object}] the query's arguments
        # @return [Array(QuerySpecification::Common::Options, Hash), nil] the specification and its
        #   normalized arguments, or nil when the store does not answer the query
        # @raise [Runtime::UnknownVerb] if `query_name` names no declared query
        def store_specification(domain, aggregate, query_name, args)
          return nil if query_name.include?(".")

          declared = declared_query(aggregate, query_name)
          return nil if aggregate.query_binding(declared.name) || answering_plugin(domain, aggregate, declared)

          args = normalize_args(aggregate, declared, args)
          declared = TenantScope.apply(declared, args)
          [ReferenceHop.apply(declared, args, registry: @registry, domain: domain, aggregate: aggregate), args]
        end
      end
    end
  end
end

Hecks::Runtime::QueryInterpreter.include(Hecks::Runtime::QueryInterpreter::StoreSpecification)

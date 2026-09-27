require "delegate"
require_relative "errors"
require_relative "refusal_wording"
require_relative "../query_specification/common/where_clause"

module Hecks
  module Runtime
    # Enforces the `authorize policy, tenant: :field` boundary as a synthetic `eq` where-clause.
    # `Scoped` goes only to query engines; IR-level calls on it would bypass the override.
    module TenantScope
      module_function

      # Wraps a declared query/read-model spec with its tenant boundary clause, if it has one.
      #
      # @param declared [Bluebook::Query, Bluebook::ReadModel] the declared specification to
      #   scope
      # @param args [Hash] the query's arguments, checked for the declared tenant field
      # @return [Bluebook::Query, Bluebook::ReadModel, Runtime::TenantScope::Scoped]
      #   `declared` unchanged when it declares no `authorize policy, tenant:`; otherwise a
      #   `Scoped` wrapper whose `#wheres` adds the tenant `eq` clause
      # @raise [Runtime::Unauthorized] if `declared` declares a tenant boundary and `args`
      #   omits that field
      def apply(declared, args)
        tenant = declared.authorization&.tenant
        return declared unless tenant

        tenant = tenant.to_sym
        unless args.key?(tenant)
          raise Unauthorized, RefusalWording.render_site("Unauthorized", "tenant_required",
                                                         query: declared.name, field: tenant)
        end

        Scoped.new(declared, QuerySpecification::Common::WhereClause.new(field: tenant, op: "eq", value: tenant))
      end

      # A SimpleDelegator whose #wheres has the tenant clause appended.
      class Scoped < SimpleDelegator
        # @param declared [Bluebook::Query, Bluebook::ReadModel] the specification to wrap,
        #   delegated to for everything but `#wheres`
        # @param clause [QuerySpecification::Common::WhereClause] the synthetic tenant `eq`
        #   clause to append
        def initialize(declared, clause)
          super(declared)
          @clause = clause
        end

        # Reads the wrapped specification's where-clauses, with the tenant clause appended.
        #
        # @return [Array<QuerySpecification::Common::WhereClause>] `declared.wheres` with the
        #   tenant clause appended
        def wheres = __getobj__.wheres + [@clause]
      end
    end
  end
end

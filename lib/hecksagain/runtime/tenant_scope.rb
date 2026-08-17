require "delegate"
require_relative "errors"
require_relative "refusal_wording"
require_relative "../query_specification/common/where_clause"

module Hecksagain
  module Runtime
    # `authorize policy, tenant: :field` declared a tenant boundary that
    # nothing enforced — the policy name and the field were stored and read
    # by nothing at dispatch time. This is the half that CAN be enforced
    # without a caller-identity/session system: the boundary itself, made
    # mandatory. Whether THIS caller actually holds `policy` for THIS
    # tenant needs real identity infrastructure this runtime does not have
    # — that stays a named, open gap, not something this quietly pretends
    # to answer.
    #
    # Enforcement is a synthetic `eq` where-clause, symbol-valued exactly
    # the way a dynamic `where(field: :arg_name)` already resolves against
    # args in every engine (QueryInterpreter#interpret,
    # Ports::Query::InMemory, both SQL adapters via SqlQueryBuilder) — so
    # every engine that already reads `.wheres` enforces the boundary for
    # free, with no per-engine code and no way for one engine to forget it.
    # `Scoped` is handed only to those engines as their `declared`/
    # `specification` argument — never returned to a caller that might call
    # an IR-level method (`filtered_head_name`, `to_h`, …) whose OWN
    # internal `wheres` call would resolve against the original object, not
    # this override, since `SimpleDelegator` only intercepts calls made
    # directly on the wrapper.
    module TenantScope
      module_function

      def apply(declared, args)
        tenant = declared.authorization&.tenant
        return declared unless tenant

        tenant = tenant.to_sym
        unless args.key?(tenant)
          raise Unauthorized, RefusalWording.render("Unauthorized", "tenant_required",
                                                    query: declared.name, field: tenant)
        end

        Scoped.new(declared, QuerySpecification::Common::WhereClause.new(field: tenant, op: "eq", value: tenant))
      end

      class Scoped < SimpleDelegator
        def initialize(declared, clause)
          super(declared)
          @clause = clause
        end

        def wheres = __getobj__.wheres + [@clause]
      end
    end
  end
end

require "delegate"
require_relative "../query_specification/common/where_clause"
require_relative "../query_specification/common/options"
require_relative "../query_specification/hop_path"
require_relative "../ports/query"
require_relative "registry"

module Hecks
  module Runtime
    # Folds each hop where-clause into a synthetic local `in` clause, the same trick
    # `TenantScope` uses, so any engine that already reads `.wheres` handles a hop for free.
    module ReferenceHop
      module_function

      # Folds every hop clause in `declared.wheres` into a synthetic local `in` clause.
      def apply(declared, args, registry:, domain:, aggregate:)
        hopped, local = declared.wheres.partition { |clause| QuerySpecification::HopPath.hop_head?(clause.field, aggregate.attributes) }
        return declared if hopped.empty?

        folded = hopped.map { |clause| fold(clause, args, registry: registry, domain: domain, aggregate: aggregate) }
        Folded.new(declared, local + folded)
      end

      # Folds one hop clause into a synthetic `in` clause over the hop attribute's own ids.
      def fold(clause, args, registry:, domain:, aggregate:)
        step = QuerySpecification::HopPath.next_hop(clause.field, aggregate.attributes)
        hop, rest = step

        # BluebookBuilder#validate_query_hops! already checked this hop at boot; if it
        # still fails to resolve here, raise rather than silently matching everything.
        unless hop&.target
          raise WiringError,
                "#{clause.field} hops through a reference this domain cannot resolve " \
                "right now — the chapter seal already checked this once; something " \
                "changed between then and this dispatch"
        end

        inner = QuerySpecification::Common::WhereClause.new(field: rest, op: clause.op, value: clause.value)
        ids   = matching_ids(domain, hop.target, [inner], args, registry: registry)

        QuerySpecification::Common::WhereClause.new(field: hop.attribute.name, op: "in", value: ids)
      end

      # Every id the inner clause(s) admit on `target`, queried through `target`'s own
      # repository — which may be bound to a different engine than the outer aggregate.
      def matching_ids(domain, target, wheres, args, registry:)
        spec       = apply(QuerySpecification::Common::Options.new(wheres: wheres), args,
                           registry: registry, domain: domain, aggregate: target)
        repository = registry.repository(domain, target)
        rows       = Ports::Query.execute(repository, spec, args, context: { domain: domain, aggregate: target }) ||
                     Ports::Query::InMemory.execute(repository.all, spec, args)

        rows.map { |row| row.id.to_s }.uniq
      end

      # SimpleDelegator only intercepts calls made directly on this wrapper, so never
      # hand it to a caller that reads `wheres` via an IR-level method like `to_h`.
      class Folded < SimpleDelegator
        def initialize(declared, wheres)
          super(declared)
          @wheres = wheres
        end

        attr_reader :wheres
      end
    end
  end
end

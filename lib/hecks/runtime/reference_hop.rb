require "delegate"
require_relative "../query_specification/common/where_clause"
require_relative "../query_specification/common/options"
require_relative "../query_specification/hop_path"
require_relative "../ports/query"
require_relative "registry"

module Hecks
  module Runtime
    # `TenantScope`'s sibling — a hop folds to a synthetic `in`
    # where-clause the exact same way a tenant boundary folds to a
    # synthetic `eq` one, so every engine that already reads `.wheres`
    # answers a hop for free, with no per-engine code and no way for
    # one engine to forget it.
    #
    # A hop's own filtering never happens here — resolving one hop
    # means running one ordinary, adapter-agnostic query against the
    # hop's target aggregate (through the same Ports::Query boundary
    # any other query goes through), and folding the ids it answers
    # back in as a local membership check. A multi-hop chain resolves
    # from the far end inward: `fold` only ever peels off the head hop
    # (QuerySpecification::HopPath.next_hop, the one-step primitive),
    # and hands everything still left in the tail to a recursive
    # `apply` call — so hop 2, hop 3, and so on each get resolved by
    # their own ordinary query against their own target, one recursion
    # level at a time, never by this module trying to see the whole
    # chain at once. It terminates because each recursion is over a
    # strictly shorter dotted string, and
    # BluebookBuilder#validate_query_hops! already refused any chain
    # deep enough to matter before this ever runs.
    module ReferenceHop
      module_function

      # Folds every hop clause in `declared.wheres` into a synthetic local `in` clause.
      #
      # @param declared [Bluebook::Query, Runtime::TenantScope::Scoped,
      #   QuerySpecification::Common::Options] the declared query specification to fold hop
      #   clauses of
      # @param args [Hash] the query's arguments, read when resolving each hop's own query
      # @param registry [Runtime::Registry] the booted registry to resolve each hop's target
      #   repository from
      # @param domain [String] the domain `aggregate` belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate `declared` queries
      # @return [Bluebook::Query, Runtime::TenantScope::Scoped, QuerySpecification::Common::
      #   Options, Hecks::Runtime::ReferenceHop::Folded] `declared` unchanged when it has no
      #   hop clauses; otherwise a `Folded` wrapper whose `#wheres` replaces each hop clause
      #   with its folded `in` clause
      # @raise [Runtime::WiringError] if a hop's target no longer resolves (see `fold`)
      def apply(declared, args, registry:, domain:, aggregate:)
        hopped, local = declared.wheres.partition { |clause| QuerySpecification::HopPath.hop_head?(clause.field, aggregate.attributes) }
        return declared if hopped.empty?

        folded = hopped.map { |clause| fold(clause, args, registry: registry, domain: domain, aggregate: aggregate) }
        Folded.new(declared, local + folded)
      end

      # Folds one hop clause into a synthetic `in` clause over the hop attribute's own ids.
      #
      # @param clause [QuerySpecification::Common::WhereClause] the hop clause to fold; its
      #   `field` names the hop path, dotted past the first segment
      # @param args [Hash] the query's arguments, read when resolving the inner query
      # @param registry [Runtime::Registry] the booted registry to resolve the hop's target
      #   repository from
      # @param domain [String] the domain `aggregate` belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate `clause` is declared against
      # @return [QuerySpecification::Common::WhereClause] a synthetic `in` clause on the hop
      #   attribute's name, whose value is every id the inner clause admits on the target
      # @raise [Runtime::WiringError] if the hop's target aggregate no longer resolves
      def fold(clause, args, registry:, domain:, aggregate:)
        step = QuerySpecification::HopPath.next_hop(clause.field, aggregate.attributes)
        hop, rest = step

        # A guarantee BluebookBuilder#validate_query_hops! already gave
        # this exact clause before the domain ever booted. Held anyway:
        # an unresolvable target folding silently to "matches
        # everything" is precisely the failure shape this whole feature
        # exists to close, and a hop that can no longer resolve (a
        # target aggregate unloaded after boot, say) is a real fact
        # worth a real error, not a query that quietly stops filtering.
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

      # Every id the inner clause admits on the hop's target — one
      # whole, ordinary query against the target's own repository,
      # through the very same Ports::Query boundary the outer ask
      # uses, so a hop is answered by whatever engine the target
      # aggregate is actually bound to (which may not be the engine
      # the outer aggregate is bound to at all) rather than by a
      # second reading of the comparators.
      #
      # @param domain [String] the domain `target` belongs to
      # @param target [Bluebook::Aggregate] the hop's target aggregate to query
      # @param wheres [Array<QuerySpecification::Common::WhereClause>] the inner clause(s) to
      #   run against `target`
      # @param args [Hash] the outer query's arguments, read when resolving the inner query
      # @param registry [Runtime::Registry] the booted registry to resolve `target`'s
      #   repository from
      # @return [Array<String>] every distinct id the inner clause(s) admit on `target`
      # @raise [Runtime::WiringError] if a hop nested inside `wheres` no longer resolves
      def matching_ids(domain, target, wheres, args, registry:)
        spec       = apply(QuerySpecification::Common::Options.new(wheres: wheres), args,
                           registry: registry, domain: domain, aggregate: target)
        repository = registry.repository(domain, target)
        rows       = Ports::Query.execute(repository, spec, args, context: { domain: domain, aggregate: target }) ||
                     Ports::Query::InMemory.execute(repository.all, spec, args)

        rows.map { |row| row.id.to_s }.uniq
      end

      # Never returned to a caller that might call an IR-level method
      # (`to_h`, …) whose own internal `wheres` read would resolve
      # against the original object, not this override — the exact
      # caution TenantScope::Scoped's own comment gives, for the exact
      # same reason: SimpleDelegator only intercepts calls made
      # directly on the wrapper.
      class Folded < SimpleDelegator
        # @param declared [Bluebook::Query, Runtime::TenantScope::Scoped,
        #   QuerySpecification::Common::Options] the wrapped query specification, delegated to
        #   for everything but `#wheres`
        # @param wheres [Array<QuerySpecification::Common::WhereClause>] the replacement
        #   where-clauses, hop clauses folded to synthetic `in` clauses
        def initialize(declared, wheres)
          super(declared)
          @wheres = wheres
        end

        attr_reader :wheres
      end
    end
  end
end

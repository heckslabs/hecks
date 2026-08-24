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
    # A hop's own filtering never happens here — RESOLVING one hop
    # means running one ordinary, adapter-agnostic query against the
    # hop's TARGET aggregate (through the same Ports::Query boundary
    # any other query goes through), and folding the ids it answers
    # back in as a local membership check. A multi-hop chain resolves
    # from the FAR END inward: `fold` only ever peels off the head hop
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

      def apply(declared, args, registry:, domain:, aggregate:)
        hopped, local = declared.wheres.partition { |clause| QuerySpecification::HopPath.hop_head?(clause.field, aggregate.attributes) }
        return declared if hopped.empty?

        folded = hopped.map { |clause| fold(clause, args, registry: registry, domain: domain, aggregate: aggregate) }
        Folded.new(declared, local + folded)
      end

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

      # Every id the inner clause admits on the hop's TARGET — one
      # whole, ordinary query against the target's own repository,
      # through the very same Ports::Query boundary the outer ask
      # uses, so a hop is answered by whatever engine the target
      # aggregate is actually bound to (which may not be the engine
      # the OUTER aggregate is bound to at all) rather than by a
      # second reading of the comparators.
      def matching_ids(domain, target, wheres, args, registry:)
        spec       = apply(QuerySpecification::Common::Options.new(wheres: wheres), args,
                           registry: registry, domain: domain, aggregate: target)
        repository = registry.repository(domain, target)
        rows       = Ports::Query.execute(repository, spec, args, context: { domain: domain, aggregate: target }) ||
                     Ports::Query::InMemory.execute(repository.all, spec, args)

        rows.map { |row| row.id.to_s }.uniq
      end

      # Never returned to a caller that might call an IR-level method
      # (`to_h`, …) whose OWN internal `wheres` read would resolve
      # against the original object, not this override — the exact
      # caution TenantScope::Scoped's own comment gives, for the exact
      # same reason: SimpleDelegator only intercepts calls made
      # directly on the wrapper.
      class Folded < SimpleDelegator
        def initialize(declared, wheres)
          super(declared)
          @wheres = wheres
        end

        def wheres = @wheres
      end
    end
  end
end

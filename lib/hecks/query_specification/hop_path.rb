require_relative "../naming"

module Hecks
  module QuerySpecification
    # One reading of a dotted query-field path that hops through a
    # reference into another aggregate's own shape — FieldPath's
    # sibling, not its member. FieldPath walks a shape, which cannot
    # loop, and answers nil, never raising, because there is nothing
    # left to say beyond "not found." HopPath walks the reference
    # graph instead — `BluebookBuilder#validate_no_bidirectional_references!`
    # refuses any reference cycle at declaration time (ADR 0025,
    # "References" — widened from a direct pair to any ring, DFS over
    # the chapter's own reference graph), so what's left to guard here
    # is depth, not cycles: MAX_HOPS below, and this module's own
    # `refusal` states for a target the chapter doesn't resolve. A walk
    # here still needs to say why it stopped, not just that it did.
    #
    # Every method below takes an attribute array, never a "shape"
    # object — deliberately, because the two real callers hold their
    # attributes differently. `AggregateBuilder` (tier-1 seal, mid-
    # build) exposes `attributes` as a plain reader, but its own
    # `attribute(name, type = String, ...)` is the DSL's attribute-
    # declaring method — calling it as a finder would silently mint a
    # new String attribute instead of looking one up. A sealed
    # `Aggregate` (tier-2 seal, and every runtime target) has a
    # real `attribute(name)` finder, but taking the array either way
    # sidesteps the mismatch instead of asking every caller to know
    # which kind of object it holds.
    module HopPath
      module_function

      Hop = Struct.new(:attribute, :target_name, :target, keyword_init: true)

      # refusal: nil (clean), :unresolvable (a hop's target cannot be
      # found — cross-domain, or simply not declared in this chapter),
      # :too_deep (see MAX_HOPS below).
      Plan = Struct.new(:hops, :tail, :refusal, keyword_init: true)

      # A hop chain long enough to matter is long enough to be a
      # mistake — not a guard against a walk that cannot terminate.
      # Nothing here loops forever regardless of how the reference
      # graph is shaped: a hop chain is a literal dotted string, fixed
      # at declaration time, and every step consumes exactly one of
      # its own segments — the walk is bounded by what was typed, not
      # by the graph. A self-referential aggregate hopping through
      # itself more than once (`"parent.parent.name"`, a grandparent
      # query) is real, common, and perfectly safe; this exists only
      # to refuse a chain nobody meant to write this long.
      MAX_HOPS = 8

      # Names the path segment a reference attribute answers to.
      #
      # The segment name a Reference answers to in a hop path — its own
      # declared attribute name, unchanged (ADR 0025, "References":
      # `reference_to` mints that bare name, no `_id`, so there is
      # no derivation left to apply). `proposal/client` (a query hop)
      # and `proposal.client` (the Ruby accessor,
      # `Facade::Handle#define_reference_accessors`) name the same
      # concept the same way.
      #
      # @param attribute [Bluebook::Attribute] a reference-typed attribute
      # @return [String] the attribute's declared name
      def hop_name(attribute) = attribute.name.to_s

      # Decides whether a field path starts by hopping through one of the given
      # references, without resolving the reference's target.
      #
      # Does this path's head cross into another record via `/`? The
      # operator is the answer now, not a name collision to arbitrate —
      # `.` walks fields inside this record, `/` crosses into another
      # one, so a path with no `/` is never a hop, full stop, and the
      # old "a real local attribute wins first" rule (needed only
      # because `.` was overloaded for both meanings, and `client_id`
      # vs `client` was how the two were told apart) has nothing left
      # to arbitrate. Answerable from `attributes` alone — a Reference
      # knows its own `target_name` at declaration, before it can
      # `resolve` it — which is what lets the aggregate seal recognise
      # a hop it cannot yet check.
      #
      # @param field [String, Symbol] the query field path, such as `:"client/status"`
      # @param attributes [Array<Bluebook::Attribute>] the attributes of the shape the path
      #   starts from
      # @return [Boolean] `true` when the path has a `/` and the segment before the first
      #   one names a reference attribute
      def hop_head?(field, attributes)
        head, rest = field.to_s.split("/", 2)
        return false unless rest

        attributes.any? { |candidate| candidate.reference? && hop_name(candidate) == head }
      end

      # Resolves the first hop of a field path and hands back what is left to walk.
      #
      # **One step**: does `field`'s head hop through one of `attributes`'
      # own references? Answers the resolved `Hop` plus the string
      # still left to walk (itself possibly another `/`-hop, against
      # the target's own attributes, or a plain `.`-dotted field walk
      # once the hops run out) — or nil, when the head names nothing or
      # the path has no `/` at all. This is the one primitive
      # Runtime::ReferenceHop needs: it recurses hop by hop through its
      # own `apply`, one ordinary same-aggregate query at a time, and
      # never needs the whole chain resolved up front the way a seal
      # does.
      #
      # @param field [String, Symbol] the query field path, such as `"client/region/name"`
      # @param attributes [Array<Bluebook::Attribute>] the attributes of the shape the path
      #   starts from
      # @return [Array(Hop, String), nil] the hop and the rest of the path after the first
      #   `/`; the hop's `target` is `nil` when the referenced aggregate is not in the
      #   declaring chapter. `nil` when the path has no `/` or its head names no reference
      # @raise [Bluebook::DSL::Malformed] if the reference has no `declared_in` aggregate
      #   to resolve its target through
      def next_hop(field, attributes)
        head, rest = field.to_s.split("/", 2)
        return nil unless rest

        attribute = attributes.find { |candidate| candidate.reference? && hop_name(candidate) == head }
        return nil unless attribute

        hop = Hop.new(attribute: attribute, target_name: attribute.type.target_name, target: attribute.type.resolve)
        [hop, rest]
      end

      # Resolves every hop of a field path in order, stopping with a reason at
      # the first one it cannot follow.
      #
      # The whole chain, resolved — every hop's target found, in
      # order — for the one caller that needs it all at once:
      # `BluebookBuilder#validate_query_hops!`, checking a hop chain
      # before anything ever dispatches it.
      #
      # @param field [String, Symbol] the query field path, such as `"client/region/name"`
      # @param attributes [Array<Bluebook::Attribute>] the attributes of the shape the path
      #   starts from
      # @return [Plan] `hops` walked so far; `tail` the remaining `.`-dotted field (`nil`
      #   on refusal); `refusal` `nil` when clean, `:unresolvable` when the last hop's
      #   target is not found, `:too_deep` when the chain exceeds `MAX_HOPS`
      # @raise [Bluebook::DSL::Malformed] if a reference on the path has no `declared_in`
      #   aggregate to resolve its target through
      def plan(field, attributes)
        hops = []
        remaining = field.to_s
        current = attributes

        loop do
          step = next_hop(remaining, current)
          break unless step

          hop, rest = step
          return Plan.new(hops: hops, tail: nil, refusal: :too_deep) if hops.size >= MAX_HOPS

          # Pushed even unresolved — a caller reporting :unresolvable
          # needs this hop's own target_name (real, known at
          # declaration, regardless of whether resolve succeeded), not
          # whatever hop came before it. `.target` is nil on this one
          # entry; every caller checking `hops.last.target` already has
          # to handle that, the same way `next_hop`'s own caller does.
          hops << hop
          return Plan.new(hops: hops, tail: nil, refusal: :unresolvable) unless hop.target

          current = hop.target.attributes
          remaining = rest
        end

        Plan.new(hops: hops, tail: remaining, refusal: nil)
      end
    end
  end
end

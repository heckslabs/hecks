require_relative "../naming"

module Hecks
  module QuerySpecification
    # ONE reading of a dotted query-field path that hops THROUGH a
    # reference into another aggregate's own shape — FieldPath's
    # sibling, not its member. FieldPath walks a SHAPE, which cannot
    # loop, and answers nil, never raising, because there is nothing
    # left to say beyond "not found." HopPath walks the REFERENCE
    # GRAPH instead — `BluebookBuilder#validate_no_bidirectional_references!`
    # refuses any reference CYCLE at declaration time (ADR 0025,
    # "References" — widened from a direct pair to any ring, DFS over
    # the chapter's own reference graph), so what's left to guard here
    # is depth, not cycles: MAX_HOPS below, and this module's own
    # `refusal` states for a target the chapter doesn't resolve. A walk
    # here still needs to say WHY it stopped, not just that it did.
    #
    # Every method below takes an ATTRIBUTE ARRAY, never a "shape"
    # object — deliberately, because the two real callers hold their
    # attributes differently. `AggregateBuilder` (tier-1 seal, mid-
    # build) exposes `attributes` as a plain reader, but its own
    # `attribute(name, type = String, ...)` is the DSL's attribute-
    # DECLARING method — calling it as a finder would silently mint a
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
      # mistake — NOT a guard against a walk that cannot terminate.
      # Nothing here loops forever regardless of how the reference
      # graph is shaped: a hop chain is a literal dotted string, fixed
      # at declaration time, and every step consumes exactly one of
      # its own segments — the walk is bounded by what was TYPED, not
      # by the graph. A self-referential aggregate hopping through
      # itself more than once (`"parent.parent.name"`, a grandparent
      # query) is real, common, and perfectly safe; this exists only
      # to refuse a chain nobody meant to write this long.
      MAX_HOPS = 8

      # The segment name a Reference answers to in a hop path — its own
      # declared attribute name, unchanged (ADR 0025, "References":
      # `reference_to` mints that bare name now, no `_id`, so there is
      # no derivation left to apply). `proposal/client` (a query hop)
      # and `proposal.client` (the Ruby accessor,
      # `Facade::Handle#define_reference_accessors`) name the same
      # concept the same way.
      def hop_name(attribute) = attribute.name.to_s

      # Does this path's HEAD cross into another record via `/`? THE
      # OPERATOR IS THE ANSWER NOW, not a name collision to arbitrate —
      # `.` walks fields inside this record, `/` crosses into another
      # one, so a path with no `/` is never a hop, full stop, and the
      # OLD "a real local attribute wins first" rule (needed only
      # because `.` was overloaded for both meanings, and `client_id`
      # vs `client` was how the two were told apart) has nothing left
      # to arbitrate. Answerable from `attributes` alone — a Reference
      # knows its own `target_name` at declaration, before it can
      # `resolve` it — which is what lets the AGGREGATE seal recognise
      # a hop it cannot yet check.
      def hop_head?(field, attributes)
        head, rest = field.to_s.split("/", 2)
        return false unless rest

        attributes.any? { |candidate| candidate.reference? && hop_name(candidate) == head }
      end

      # ONE STEP: does `field`'s head hop through one of `attributes`'
      # own references? Answers the resolved `Hop` plus the string
      # still left to walk (itself possibly another `/`-hop, against
      # the TARGET's own attributes, or a plain `.`-dotted field walk
      # once the hops run out) — or nil, when the head names nothing or
      # the path has no `/` at all. This is the one primitive
      # Runtime::ReferenceHop needs: it recurses hop by hop through its
      # own `apply`, one ordinary same-aggregate query at a time, and
      # never needs the whole chain resolved up front the way a seal
      # does.
      def next_hop(field, attributes)
        head, rest = field.to_s.split("/", 2)
        return nil unless rest

        attribute = attributes.find { |candidate| candidate.reference? && hop_name(candidate) == head }
        return nil unless attribute

        hop = Hop.new(attribute: attribute, target_name: attribute.type.target_name, target: attribute.type.resolve)
        [hop, rest]
      end

      # The WHOLE chain, resolved — every hop's target found, in
      # order — for the one caller that needs it all at once:
      # BluebookBuilder#validate_query_hops!, checking a hop chain
      # before anything ever dispatches it.
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
          # needs THIS hop's own target_name (real, known at
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

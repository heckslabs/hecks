require_relative "../naming"

module Hecksagain
  module QuerySpecification
    # ONE reading of a dotted query-field path that hops THROUGH a
    # reference into another aggregate's own shape — FieldPath's
    # sibling, not its member. FieldPath walks a SHAPE, which cannot
    # loop, and answers nil, never raising, because there is nothing
    # left to say beyond "not found." HopPath walks the REFERENCE
    # GRAPH instead, which the language does not guarantee acyclic —
    # aggregates only refuse a DIRECT bidirectional pair
    # (BluebookBuilder#validate_no_bidirectional_references! explicitly
    # declines to take a position on a longer ring) — so a walk here
    # needs to say WHY it stopped, not just that it did.
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

      # The segment name a Reference answers to in a dotted query path
      # — Naming.reference_hop, the same rule
      # Facade::Handle#define_reference_accessors already hydrates its
      # own accessors from, so `proposal.client` (the Ruby accessor)
      # and `:"client.status"` (the query hop) name one concept
      # identically.
      def hop_name(attribute)
        Naming.reference_hop(attribute.name, Naming.snake(attribute.type.target_name))
      end

      # Does this path's HEAD name one of `attributes`' own references?
      # A real LOCAL attribute of that name wins first, whatever it
      # is — a hop is spelled by its accessor name, never its storage
      # name, so `client_id` (the raw attribute) is never read as a
      # hop even though `client` (its accessor) is. Answerable from
      # `attributes` alone — a Reference knows its own `target_name`
      # at declaration, before it can `resolve` it — which is what
      # lets the AGGREGATE seal recognise a hop it cannot yet check.
      def hop_head?(field, attributes)
        head, *rest = field.to_s.split(".")
        return false if rest.empty?
        return false if attributes.any? { |candidate| candidate.name.to_s == head }

        attributes.any? { |candidate| candidate.reference? && hop_name(candidate) == head }
      end

      # ONE STEP: does `field`'s head hop through one of `attributes`'
      # own references? Answers the resolved `Hop` plus the dotted
      # string still left to walk (itself possibly another hop,
      # against the TARGET's own attributes) — or nil, when the head
      # is a real local attribute or names nothing at all. This is
      # the one primitive Runtime::ReferenceHop needs: it recurses hop
      # by hop through its own `apply`, one ordinary same-aggregate
      # query at a time, and never needs the whole chain resolved up
      # front the way a seal does.
      def next_hop(field, attributes)
        head, *rest = field.to_s.split(".")
        return nil if rest.empty?
        return nil if attributes.any? { |candidate| candidate.name.to_s == head }

        attribute = attributes.find { |candidate| candidate.reference? && hop_name(candidate) == head }
        return nil unless attribute

        hop = Hop.new(attribute: attribute, target_name: attribute.type.target_name, target: attribute.type.resolve)
        [hop, rest.join(".")]
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

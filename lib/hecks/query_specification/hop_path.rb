require_relative "../naming"

module Hecks
  module QuerySpecification
    # One reading of a dotted query-field path that hops through a reference with `/`.
    #
    # Takes attribute arrays, not shapes: AggregateBuilder's `attribute(name)` declares rather
    # than finds, so the two real callers cannot share a finder.
    module HopPath
      module_function

      Hop = Struct.new(:attribute, :target_name, :target, keyword_init: true)

      # `refusal` is nil when clean, `:unresolvable` when a hop's target is not found,
      # `:too_deep` when the chain exceeds MAX_HOPS.
      Plan = Struct.new(:hops, :tail, :refusal, keyword_init: true)

      # Bounds hop chains: a longer one is a mistake, not a runaway walk, since each
      # step consumes one segment of the typed path.
      MAX_HOPS = 8

      # Names the path segment a reference attribute answers to.
      #
      # The attribute's own declared name, unchanged (ADR 0025).
      #
      # @param attribute [Bluebook::Attribute] a reference-typed attribute
      # @return [String] the attribute's declared name
      def hop_name(attribute) = attribute.name.to_s

      # Decides whether a field path starts by hopping through one of the given
      # references, without resolving the reference's target.
      #
      # A path with no `/` is never a hop: `.` walks fields inside a record, `/` crosses
      # into another one.
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

          # Pushed even unresolved: a caller reporting :unresolvable needs this hop's
          # target_name, and `.target` is nil on this one entry.
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

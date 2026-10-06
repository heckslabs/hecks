module Hecks
  module Translation
    module Audit
      # New-era attributes that nothing feeds: no translated state, rule or default supplies them.
      # A report, not a violation; a required one is refused by Layer 1 once an invariant reads it.
      module UnfedReport
        # Lists the current era's attributes that no rule, default or translated record feeds.
        #
        # @param aggregate [Bluebook::Aggregate] the current era's IR for the aggregate
        # @param declared [Bluebook::TranslationAggregate, nil] this edge's rules; the
        #   destinations of its renames, moves, converts and computes count as fed
        # @param after [Hash{String => Hash}] translated state per record id
        # @return [Array<String>] names of unfed attributes, in declaration order; `[]` when
        #   every attribute is fed or `after` holds no records
        def unfed(aggregate, declared, after)
          return [] if after.empty?

          fed = fed_names(declared)
          aggregate.attributes.filter_map do |attribute|
            name = attribute.name.to_s
            name unless fed.include?(name) || !attribute.default.nil? || after.any? { |_, state| !dig_path(state, name).nil? }
          end
        end

        # The top-level attribute names an edge's destinations feed.
        #
        # @param declared [Bluebook::TranslationAggregate, nil] this edge's rules
        # @return [Array<String>] the destinations of renames, moves, converts and computes, cut to
        #   their top-level name; `[]` when there is no edge
        def fed_names(declared)
          return [] unless declared

          rules = [declared.moves, declared.converts, declared.computes].flat_map { |list| list.map(&:to) }
          (declared.renames.values.map(&:to_s) + rules).map { |path| path.to_s.split(".").first }
        end

        # Reads a dotted path out of a state whose keys may be Strings or Symbols.
        #
        # @param state [Hash, nil] the state to read
        # @param path [String, Symbol] a bare or dotted path, such as `"price.cents"`
        # @return [Object, nil] the value held at the path, `false` included; nil when `state`
        #   is nil, a segment is absent, or a segment's parent is not a Hash
        def dig_path(state, path)
          return nil if state.nil?

          path.to_s.split(".").reduce(state) do |node, segment|
            break nil unless node.is_a?(Hash)

            # `key?`, not `||`: a held `false` must not fall through and read as nil (unfed).
            node.key?(segment) ? node[segment] : node[segment.to_sym]
          end
        end
      end
    end
  end
end

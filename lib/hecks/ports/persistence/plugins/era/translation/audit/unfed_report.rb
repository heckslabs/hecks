module Hecks
  module Translation
    module Audit
      # New-era attributes that nothing feeds: absent from every
      # translated state, produced by no rule, and carrying no default.
      # A report, not a violation — the remedy is a `default:` on the
      # attribute, and the loud refusal for a required one comes from
      # Layer 1 the moment an invariant reads it.
      module UnfedReport
        # Lists the current era's attributes that no rule, default or translated record feeds.
        #
        # `fed` build-up plus one ordered guard chain per attribute
        # (already fed, has a default, actually present in some record, no
        # records to check at all) answering a single question — "is
        # anything, ever, going to feed this field" — where each `next`
        # rules out one way the answer is "not unfed after all" before the
        # next is even worth asking. Splitting the guards out would just
        # turn each into a same-shaped one-line predicate call.
        #
        # @param aggregate [Bluebook::Aggregate] the current era's IR for the aggregate
        # @param declared [Bluebook::TranslationAggregate, nil] this edge's rules; the
        #   destinations of its renames, moves, converts and computes count as fed
        # @param after [Hash{String => Hash}] translated state per record id
        # @return [Array<String>] names of unfed attributes, in declaration order; `[]` when
        #   every attribute is fed or `after` holds no records
        # rubocop:disable-next Metrics/CyclomaticComplexity
        # rubocop:disable-next Metrics/PerceivedComplexity
        def unfed(aggregate, declared, after)
          fed = if declared
                  (declared.renames.values.map(&:to_s) +
                   declared.moves.map(&:to) +
                   declared.converts.map(&:to) +
                   declared.computes.map(&:to)).map { |path| path.to_s.split(".").first }
                else
                  []
                end
          aggregate.attributes.filter_map do |attribute|
            name = attribute.name.to_s
            next if fed.include?(name)
            next unless attribute.default.nil?
            next if after.any? { |_, state| !dig_path(state, name).nil? }
            next if after.empty?

            name
          end
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

            # `key?` decides which spelling answers, never `||` — a
            # `false` genuinely held at this path must not fall through
            # to the other spelling (usually absent) and read as `nil`,
            # which would wrongly mark a `false`-valued attribute "unfed".
            node.key?(segment) ? node[segment] : node[segment.to_sym]
          end
        end
      end
    end
  end
end

require_relative "../../../../../../ports/persistence/append_only"
require_relative "../../lineage"

module Hecks
  module Translation
    module Audit
      # Layer 2: from the edge alone, per-rule value preservation and id-set conservation.
      module LayerTwo
        # Checks one aggregate's records across the edge for id conservation and, where a
        # per-record comparison is possible, agreement with the reference transform.
        #
        # Compute paths and rekeyed aggregates are exempt from the comparison.
        #
        # @param violations [Array<String>] collector this method appends messages to
        # @param aggregate [Bluebook::Aggregate] the current era's IR for the aggregate
        # @param declared [Bluebook::TranslationAggregate, nil] nil limits the check to ids
        # @param before [Hash{String => Hash}] source state per record id, as parsed JSON
        # @param after [Hash{String => Hash}] translated state per record id, as parsed JSON
        # @return [void]
        # @raise [Runtime::WiringError] if the reference transform cannot translate `before`
        def layer_two!(violations, aggregate, declared, before, after)
          rekeyed = declared && !declared.rekeys.empty?

          check_id_conservation!(violations, aggregate, before, after, rekeyed: rekeyed)

          return unless declared
          # A rekey's SQL is its only implementation and `after` cannot be looked up by old id.
          return if rekeyed

          check_value_preservation!(violations, aggregate, declared, before, after)
        end

        # Records a violation when the edge loses, gains or collides record ids.
        #
        # @param violations [Array<String>] collector this method appends at most one message to
        # @param aggregate [Bluebook::Aggregate] the aggregate, named in the message
        # @param before [Hash{String => Hash}] source state per record id
        # @param after [Hash{String => Hash}] translated state per record id
        # @param rekeyed [Boolean, nil] truthy when the edge rekeys, which compares record
        #   counts instead of id sets
        # @return [void]
        def check_id_conservation!(violations, aggregate, before, after, rekeyed:)
          # A rekey changes the id set, so compare counts: a collision or a NULL id lowers it.
          message = rekeyed ? rekey_count_violation(aggregate, before, after) : id_set_violation(aggregate, before, after)
          violations << message if message
        end

        # Records a violation for each record whose translated state diverges from the reference.
        # Assumes the edge is declared and does not rekey.
        #
        # @param violations [Array<String>] mutated in place with one message per divergent id
        # @param aggregate [Bluebook::Aggregate] the aggregate being audited
        # @param declared [Bluebook::Translation] the declared translation to check against
        # @param before [Hash{String => Hash}] source records, keyed by id
        # @param after [Hash{String => Hash}] translated records, keyed by id
        # @return [void]
        def check_value_preservation!(violations, aggregate, declared, before, after)
          rules = Ports::Persistence::Lineage.from_declared(declared, aggregate.name)
          compute_paths = compute_paths_of(declared)

          before.each do |id, state|
            next unless after.key?(id)

            diverged = divergence(rules, id, state, after[id], compute_paths)
            next if diverged.empty?

            violations << "#{aggregate.name}##{id}: the translated state diverges from the reference " \
                          "transform at #{diverged.sort.join(", ")}"
          end
        end

        # Round-trips state through JSON so both sides of the comparison share one spelling.
        #
        # @param state [Hash, nil] a state with Symbol or String keys
        # @return [Hash{String => Object}, nil] a deep copy with String keys at every depth
        def normalize(state) = JSON.parse(JSON.generate(state))

        # Removes the paths a compute owns from a normalized state, in place.
        #
        # A dotted path removes only its own member, never the whole top-level key, so sibling
        # members stay under the equivalence check and silent loss there is still caught.
        #
        # @param state [Hash{String => Object}] a normalized state; mutated
        # @param paths [Array<String>] bare (`"price_cents"`) or dotted (`"price.cents"`)
        #   compute paths
        # @return [Hash{String => Object}] `state` itself, with those paths deleted
        def strip_compute_paths(state, paths)
          paths.each do |path|
            segments = path.split(".")
            if segments.length == 1
              state.delete(segments.first)
            else
              parent = segments[0..-2].reduce(state) { |node, segment| node.is_a?(Hash) ? node[segment] : nil }
              parent.delete(segments.last) if parent.is_a?(Hash)
            end
          end
          state
        end

        private

        # The message for a rekeying edge whose record count changed, or nil.
        def rekey_count_violation(aggregate, before, after)
          return if before.keys.size == after.keys.size

          "#{aggregate.name}: the record count changed across a rekeying edge " \
            "(#{before.keys.size} before, #{after.keys.size} after) — a rekey must not " \
            "collide two distinct ids onto one, or drop one"
        end

        # The message for an edge whose id set changed, or nil.
        def id_set_violation(aggregate, before, after)
          return if before.keys.sort == after.keys.sort

          gained = after.keys - before.keys
          lost = before.keys - after.keys
          "#{aggregate.name}: the id set changed across the edge " \
            "(lost #{lost.sort.inspect}, gained #{gained.sort.inspect})"
        end

        def compute_paths_of(declared)
          declared.computes.flat_map { |compute| [compute.from, compute.to] }.map(&:to_s)
        end

        # The keys at which one record's translated state differs from the reference transform.
        def divergence(rules, id, state, translated, compute_paths)
          entry = Ports::Persistence::Entry.new(operation: "save", id: id, state: state.transform_keys(&:to_sym))
          expected = strip_compute_paths(normalize(rules.translate(entry).state), compute_paths)
          actual = strip_compute_paths(normalize(translated), compute_paths)
          (expected.keys | actual.keys).reject { |key| expected[key] == actual[key] }
        end
      end
    end
  end
end

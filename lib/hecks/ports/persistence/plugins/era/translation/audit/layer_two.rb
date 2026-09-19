require_relative "../../../../../../ports/persistence/append_only"
require_relative "../../lineage"

module Hecks
  module Translation
    module Audit
      # Layer 2 — from the edge alone: per-rule value preservation, no
      # leftover source keys, and id-set conservation across the edge.
      module LayerTwo
        # Checks one aggregate's records across the edge for id conservation and, where a
        # per-record comparison is possible, agreement with the reference transform.
        #
        # Per-rule value preservation and leftover source keys are checked
        # against the reference transform in full — never rule by rule in
        # isolation, because rules interact (a rename whose value a later
        # move partially consumes preserves exactly what the transform
        # says it preserves, no more). This makes every mint a run of the
        # cross-execution equivalence gate for the five portable rule
        # kinds: the compiled SQL produced `after`; the port's entry-JSON
        # transform produces `expected`; they must agree byte-for-byte on
        # every path a compute doesn't own. Compute paths are exempt — the
        # SQL is their only implementation, and the Layer-3 sample is
        # their only review. A rekeyed aggregate is exempt from this whole
        # per-record check, for the same reason and one more: there is no
        # old-id → new-id correspondence to look `after` up by once the id
        # itself is what changed.
        #
        # @param violations [Array<String>] collector this method appends messages to
        # @param aggregate [Bluebook::Aggregate] the current era's IR for the aggregate
        # @param declared [Bluebook::TranslationAggregate, nil] this edge's rules for the
        #   aggregate; nil limits the check to id conservation
        # @param before [Hash{String => Hash}] source state per record id, as parsed JSON
        # @param after [Hash{String => Hash}] translated state per record id, as parsed JSON
        # @return [void]
        # @raise [Runtime::WiringError] if the reference transform cannot translate a `before`
        #   state: a convert meets an unmapped value, or a move nests under a non-Hash
        def layer_two!(violations, aggregate, declared, before, after)
          rekeyed = declared && !declared.rekeys.empty?

          check_id_conservation!(violations, aggregate, before, after, rekeyed: rekeyed)

          return unless declared
          # No correspondence between an old id and its rekeyed row exists
          # in Ruby (the rekey's SQL is its only implementation, same as
          # compute's) — exempt from the per-record equivalence gate for
          # the same reason compute paths already are, extended to the
          # whole record since an old-id lookup into `after` can never
          # succeed once the id itself has changed.
          return if rekeyed

          check_value_preservation!(violations, aggregate, declared, before, after)
        end

        # Records a violation when the edge loses, gains or collides record ids.
        #
        # Record-count / id-set conservation — one of the two properties
        # this module's own header names, and independent of the other
        # (per-rule value preservation, below): it needs only `before`,
        # `after`, and whether the edge rekeyed, never the declared rules
        # themselves.
        #
        # @param violations [Array<String>] collector this method appends at most one message to
        # @param aggregate [Bluebook::Aggregate] the aggregate, named in the message
        # @param before [Hash{String => Hash}] source state per record id
        # @param after [Hash{String => Hash}] translated state per record id
        # @param rekeyed [Boolean, nil] truthy when the edge rekeys, which compares record
        #   counts instead of id sets
        # @return [void]
        def check_id_conservation!(violations, aggregate, before, after, rekeyed:)
          # A rekey legitimately changes the id set (that's the entire
          # point) — set-equality would flag every honest rekey as data
          # loss. What must still hold is record count: a botched rekey
          # colliding two distinct old ids onto one new id, or dropping one
          # (its SQL returning NULL), shows up as the count going down —
          # caught here without needing to track the old→new mapping
          # itself.
          if rekeyed
            unless before.keys.size == after.keys.size
              violations << "#{aggregate.name}: the record count changed across a rekeying edge " \
                            "(#{before.keys.size} before, #{after.keys.size} after) — a rekey must not " \
                            "collide two distinct ids onto one, or drop one"
            end
          elsif before.keys.sort != after.keys.sort
            gained = after.keys - before.keys
            lost = before.keys - after.keys
            violations << "#{aggregate.name}: the id set changed across the edge " \
                          "(lost #{lost.sort.inspect}, gained #{gained.sort.inspect})"
          end
        end

        # Per-rule value preservation — the other property this module's
        # header names. Only reached once `layer_two!` has already ruled
        # out "no declared edge" and "rekeyed" (see its own comment on
        # that second guard); this method assumes both are false.
        # @param violations [Array<String>] mutated in place with one message per divergent id
        # @param aggregate [Bluebook::Aggregate] the aggregate being audited
        # @param declared [Bluebook::Translation] the declared translation to check against
        # @param before [Hash{String => Hash}] the old world's own records, keyed by id
        # @param after [Hash{String => Hash}] the new world's own records, keyed by id
        # @return [void]
        def check_value_preservation!(violations, aggregate, declared, before, after)
          rules = Ports::Persistence::Lineage.from_declared(declared, aggregate.name)
          compute_paths = declared.computes.flat_map { |compute| [compute.from, compute.to] }.map(&:to_s)

          before.each do |id, state|
            next unless after.key?(id)

            entry = Ports::Persistence::Entry.new(operation: "save", id: id, state: state.transform_keys(&:to_sym))
            expected = strip_compute_paths(normalize(rules.translate(entry).state), compute_paths)
            actual = strip_compute_paths(normalize(after[id]), compute_paths)
            next if expected == actual

            diverged = (expected.keys | actual.keys).reject { |key| expected[key] == actual[key] }
            violations << "#{aggregate.name}##{id}: the translated state diverges from the reference " \
                          "transform at #{diverged.sort.join(', ')}"
          end
        end

        # Round-trips state through JSON so both sides of the comparison share one spelling.
        #
        # @param state [Hash, nil] a state with Symbol or String keys
        # @return [Hash{String => Object}, nil] a deep copy with String keys at every depth
        def normalize(state) = JSON.parse(JSON.generate(state))

        # Removes the paths a compute owns from a normalized state, in place.
        #
        # Exempts exactly the paths a compute owns, not the whole
        # top-level attribute it happens to live under. A bare path
        # ("price_cents") is itself the compute's entire value — dropping
        # the whole top-level key is correct, there's nothing else there
        # to check. A dotted path ("price.cents") only owns that one
        # member of the value object it reaches into; every sibling
        # member (e.g. "price.currency") is untouched by the compute and
        # must stay subject to the equivalence check below. Blanket-
        # dropping the whole top-level key for a dotted compute would
        # exempt the entire attribute — silent data loss elsewhere in the
        # same value object (a migration that nulls or drops a sibling
        # field) would produce zero violations, defeating the one gate
        # whose entire purpose is to catch exactly that.
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
      end
    end
  end
end

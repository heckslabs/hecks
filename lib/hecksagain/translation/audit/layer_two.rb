require_relative "../../ports/persistence/append_only"
require_relative "../../ports/persistence/lineage"

module Hecksagain
  module Translation
    module Audit
      # Layer 2 — from the edge alone: per-rule value preservation, no
      # leftover source keys, and id-set conservation across the edge.
      module LayerTwo
        # Per-rule value preservation and leftover source keys are checked
        # against the reference transform IN FULL — never rule by rule in
        # isolation, because rules interact (a rename whose value a later
        # move partially consumes preserves exactly what the transform
        # says it preserves, no more). This makes every mint a run of the
        # cross-execution equivalence gate for the five portable rule
        # kinds: the compiled SQL produced `after`; the port's entry-JSON
        # transform produces `expected`; they must agree byte-for-byte on
        # every path a compute doesn't own. Compute paths are exempt — the
        # SQL is their only implementation, and the Layer-3 sample is
        # their only review.
        def layer_two!(violations, aggregate, declared, before, after)
          unless before.keys.sort == after.keys.sort
            gained = after.keys - before.keys
            lost = before.keys - after.keys
            violations << "#{aggregate.name}: the id set changed across the edge " \
                          "(lost #{lost.sort.inspect}, gained #{gained.sort.inspect})"
          end
          return unless declared

          rules = Ports::Persistence::Lineage.from_declared(declared, aggregate.name)
          compute_tops = declared.computes.flat_map { |compute| [compute.from, compute.to] }
                                 .map { |path| path.to_s.split(".").first }

          before.each do |id, state|
            next unless after.key?(id)

            entry = Ports::Persistence::Entry.new(operation: "save", id: id, state: state.transform_keys(&:to_sym))
            expected = normalize(rules.translate(entry).state).reject { |key, _| compute_tops.include?(key) }
            actual = normalize(after[id]).reject { |key, _| compute_tops.include?(key) }
            next if expected == actual

            diverged = (expected.keys | actual.keys).select { |key| expected[key] != actual[key] }
            violations << "#{aggregate.name}##{id}: the translated state diverges from the reference " \
                          "transform at #{diverged.sort.join(', ')}"
          end
        end

        def normalize(state) = JSON.parse(JSON.generate(state))
      end
    end
  end
end

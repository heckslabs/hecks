require "json"
require "digest"
require "fileutils"

module Hecksagain
  module Translation
    # The audit derives its assertions; nobody hand-lists them.
    #
    # Layer 1 — from the bluebook alone: every translated state must
    # pass the new era's types, value-object invariants, and lifecycle.
    # This is also where a NEW, stricter invariant that old records
    # violate surfaces — there is no "grandfather old records" construct,
    # and the remedy is relaxing the invariant or explicit remediation,
    # never a translation rule.
    #
    # Layer 2 — from the edge alone: per-rule value preservation, no
    # leftover source keys, id-set conservation across the edge, and the
    # dropped/unfed report (an unfed required attribute is the
    # diagnostic that says "add a default:", not "write a rule").
    #
    # Layer 3 — a before/after sample of real records for HUMAN
    # approval: intent is not derivable. For a `compute` rule this
    # sample is the only verification there is — its SQL has no
    # in-process reference to be checked against, by design.
    module Audit
      module_function

      Verdict = Struct.new(:violations, :dropped, :unfed, :samples, keyword_init: true) do
        def ok? = violations.empty?
      end

      SAMPLE_SIZE = 5

      # aggregate — the CURRENT era's IR; declared — this edge's rules
      # for it (may be nil); before/after — {id => state hash}, source
      # era's latest vs translated.
      def check(aggregate:, declared:, before:, after:)
        violations = []

        layer_one!(violations, aggregate, after)
        layer_two!(violations, aggregate, declared, before, after)

        Verdict.new(
          violations: violations,
          dropped: declared ? declared.drops.map(&:to_s) : [],
          unfed: unfed(aggregate, declared, after),
          samples: before.keys.sort.first(SAMPLE_SIZE).map { |id| { id: id, before: before[id], after: after[id] } }
        )
      end

      def layer_one!(violations, aggregate, after)
        after.each do |id, state|
          begin
            symbolized = JSON.parse(JSON.generate(state), symbolize_names: true)
            instance = Runtime::Instance.new(aggregate: aggregate, id: id, state: symbolized)
            lifecycle = aggregate.lifecycle
            next unless lifecycle

            held = instance[lifecycle.field]
            allowed = lifecycle.states | [lifecycle.default]
            unless held.nil? || allowed.include?(held)
              violations << "#{aggregate.name}##{id}: #{lifecycle.field} is #{held.inspect}, " \
                            "a state this era's lifecycle never reaches"
            end
          rescue Runtime::InvariantViolation, Runtime::TypeMismatch => error
            violations << "#{aggregate.name}##{id}: #{error.message}"
          end
        end
      end

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

      # New-era attributes that nothing feeds: absent from every
      # translated state, produced by no rule, and carrying no default.
      # A report, not a violation — the remedy is a `default:` on the
      # attribute, and the loud refusal for a REQUIRED one comes from
      # Layer 1 the moment an invariant reads it.
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

      def dig_path(state, path)
        return nil if state.nil?

        path.to_s.split(".").reduce(state) do |node, segment|
          break nil unless node.is_a?(Hash)

          node[segment] || node[segment.to_sym]
        end
      end

      # ── the human gate, made real ──────────────────────────────────
      #
      # For the five portable rule kinds the mint verifies the edge
      # mechanically (Layer 2 IS the cross-execution equivalence gate).
      # A compute has no mechanical verification — the Layer-3 sample a
      # human reads is the only one there is — so a compute edge cannot
      # mint until someone has run `bin/translation_audit … --approve`.
      #
      # The approval binds to WHAT WAS ACTUALLY REVIEWED, on both axes:
      # a content digest of the parsed edge (change the edge's meaning
      # and the approval lapses; a comment does not), and the journal's
      # high-water ordinal at review time, recorded IN the target
      # database — a token in the repo could not bind to the data, and
      # samples reviewed against staging or against production-as-of-T
      # say nothing about a database that has moved on. Mint stays
      # non-interactive and its lock stays short; the human decision
      # happens in the audit tool, where the samples are.
      def edge_digest(edge)
        Digest::SHA256.hexdigest(JSON.generate(Projector::Exporter.translation_hash(edge)))
      end
    end
  end
end

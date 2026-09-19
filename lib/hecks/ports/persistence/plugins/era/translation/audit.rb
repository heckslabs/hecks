require "json"

require_relative "audit/layer_one"
require_relative "audit/layer_two"
require_relative "audit/unfed_report"
require_relative "audit/approval_digest"

module Hecks
  module Translation
    # The audit derives its assertions; nobody hand-lists them. One file
    # per layer beside this one: audit/layer_one.rb (the bluebook's own
    # rules), audit/layer_two.rb (the edge against the reference
    # transform), audit/unfed_report.rb (what nothing feeds), and
    # audit/approval_digest.rb (the human gate's binding). Layer 3 — the
    # before/after sample a human approves, intent not being derivable —
    # is assembled right here in `check`.
    module Audit
      Verdict = Struct.new(:violations, :dropped, :unfed, :samples, keyword_init: true) do
        # Reports whether the mechanical layers found nothing to refuse.
        #
        # @return [Boolean] true when `violations` is empty; `dropped`, `unfed` and `samples`
        #   are reports and never affect the answer
        def ok? = violations.empty?
      end

      SAMPLE_SIZE = 5

      extend LayerOne
      extend LayerTwo
      extend UnfedReport
      extend ApprovalDigest

      module_function

      # Audits one aggregate's records across one translation edge and gathers what a
      # human reviewer needs to see.
      #
      # @param aggregate [Bluebook::Aggregate] the current era's IR for the aggregate
      # @param declared [Bluebook::TranslationAggregate, nil] this edge's rules for the
      #   aggregate; nil when the edge declares none
      # @param before [Hash{String => Hash}] the source era's latest state per record id, as
      #   parsed JSON
      # @param after [Hash{String => Hash}] the translated state per record id, as parsed JSON
      # @return [Translation::Audit::Verdict] `violations` (Layer 1 and 2 messages), `dropped`
      #   (declared drop paths as Strings), `unfed` (attribute names nothing feeds) and
      #   `samples` (the Layer 3 before/after pairs)
      # @raise [Runtime::WiringError] if Layer 2's reference transform cannot translate a
      #   `before` state: a convert meets an unmapped value, or a move nests under a non-Hash
      def check(aggregate:, declared:, before:, after:)
        violations = []

        layer_one!(violations, aggregate, after)
        layer_two!(violations, aggregate, declared, before, after)

        Verdict.new(
          violations: violations,
          dropped:    declared ? declared.drops.map(&:to_s) : [],
          unfed:      unfed(aggregate, declared, after),
          samples:    samples_for(declared, before, after)
        )
      end

      # Picks the first `SAMPLE_SIZE` records, by sorted id, for a human to compare.
      #
      # @param declared [Bluebook::TranslationAggregate, nil] this edge's rules; a rekey among
      #   them switches to `rekeyed_samples`
      # @param before [Hash{String => Hash}] source state per record id
      # @param after [Hash{String => Hash}] translated state per record id
      # @return [Array<Hash{Symbol => Object}>] Hashes with `:id`, `:before` and `:after`;
      #   `:after` is nil for an id missing from `after`
      def samples_for(declared, before, after)
        return rekeyed_samples(before, after) if declared && !declared.rekeys.empty?

        before.keys.sort.first(SAMPLE_SIZE).map { |id| { id: id, before: before[id], after: after[id] } }
      end

      # Samples both sides of a rekeying edge separately instead of pairing them by id.
      #
      # A rekey changes the id itself, so `before`'s and `after`'s
      # keyspaces share nothing — pairing by matching id (the ordinary
      # path above) would show every `after` as nil, telling a human
      # nothing. Nothing in-process can compute the old→new
      # correspondence either (the rekey's SQL is its only
      # implementation, same as compute's own). Shown side by side
      # instead, each labelled by its own id: real records going in,
      # real records coming out — not claimed to correspond one-to-one,
      # but enough for the human this rule's only verification depends
      # on to actually see real shapes and values, not a wall of null.
      #
      # @param before [Hash{String => Hash}] source state per old record id
      # @param after [Hash{String => Hash}] translated state per new record id
      # @return [Array<Hash{Symbol => Object}>] up to `SAMPLE_SIZE` Hashes whose `:id` ends in
      #   `" (before)"` with `:after` nil, then up to `SAMPLE_SIZE` ending in `" (after)"` with
      #   `:before` nil
      def rekeyed_samples(before, after)
        before.keys.sort.first(SAMPLE_SIZE).map { |id| { id: "#{id} (before)", before: before[id], after: nil } } +
          after.keys.sort.first(SAMPLE_SIZE).map { |id| { id: "#{id} (after)", before: nil, after: after[id] } }
      end
    end
  end
end

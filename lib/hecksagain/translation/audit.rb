require "json"

require_relative "audit/layer_one"
require_relative "audit/layer_two"
require_relative "audit/unfed_report"
require_relative "audit/approval_digest"

module Hecksagain
  module Translation
    # The audit derives its assertions; nobody hand-lists them. One file
    # per layer beside this one: audit/layer_one.rb (the bluebook's own
    # rules), audit/layer_two.rb (the edge against the reference
    # transform), audit/unfed_report.rb (what nothing feeds), and
    # audit/approval_digest.rb (the human gate's binding). Layer 3 — the
    # before/after sample a HUMAN approves, intent not being derivable —
    # is assembled right here in `check`.
    module Audit
      Verdict = Struct.new(:violations, :dropped, :unfed, :samples, keyword_init: true) do
        def ok? = violations.empty?
      end

      SAMPLE_SIZE = 5

      extend LayerOne
      extend LayerTwo
      extend UnfedReport
      extend ApprovalDigest

      module_function

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
          samples: samples_for(declared, before, after)
        )
      end

      def samples_for(declared, before, after)
        return rekeyed_samples(before, after) if declared && !declared.rekeys.empty?

        before.keys.sort.first(SAMPLE_SIZE).map { |id| { id: id, before: before[id], after: after[id] } }
      end

      # A rekey changes the id itself, so `before`'s and `after`'s
      # keyspaces share nothing — pairing by matching id (the ordinary
      # path above) would show every `after` as nil, telling a human
      # nothing. Nothing in-process can compute the old→new
      # correspondence either (the rekey's SQL is its only
      # implementation, same as compute's own). Shown side by side
      # instead, each labelled by its OWN id: real records going in,
      # real records coming out — not claimed to correspond one-to-one,
      # but enough for the human this rule's only verification depends
      # on to actually see real shapes and values, not a wall of null.
      def rekeyed_samples(before, after)
        before.keys.sort.first(SAMPLE_SIZE).map { |id| { id: "#{id} (before)", before: before[id], after: nil } } +
          after.keys.sort.first(SAMPLE_SIZE).map { |id| { id: "#{id} (after)", before: nil, after: after[id] } }
      end
    end
  end
end

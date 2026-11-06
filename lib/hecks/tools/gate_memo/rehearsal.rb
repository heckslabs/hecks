# frozen_string_literal: true

require "time"
require_relative "../gate_memo"

module Hecks
  module Tools
    module GateMemo
      # Whether a mint rehearsal's copy of a ledger can be reused. Only a rehearsal that said
      # `would_mint`
      # is kept, and it is reused only while the ledger's watermark and its translation edge are the
      # ones
      # it read. Reuse never skips the mint's own check: `moved?` compares the live watermark, and
      # the
      # PostgresRevision lineage manager refuses a mint whose watermark moved.
      module Rehearsal
        # The one verdict a mint may follow.
        VERDICT = "would_mint"

        module_function

        # @param domain [String] the domain the rehearsal was for
        # @return [String] the memo key of the domain's rehearsal
        def key(domain) = "mint_rehearsal:#{domain}"

        # @return [Hash, nil] the entry to keep for a rehearsal, or nil when its verdict is not
        # would_mint
        def entry(verdict:, watermark:, edge:)
          return nil unless verdict == VERDICT

          { "verdict" => verdict, "watermark" => watermark, "edge" => edge, "at" => Time.now.utc.iso8601 }
        end

        # @return [Boolean] whether the memo's rehearsal of the domain said would_mint on this
        # watermark
        #   and this edge; false when the edge is unknown
        def reusable?(memo, domain, watermark:, edge:)
          entry = memo[key(domain)]
          !edge.nil? && entry.is_a?(Hash) && entry["verdict"] == VERDICT &&
            entry["watermark"] == watermark && entry["edge"] == edge
        end

        # @return [Boolean] whether the live watermark differs from the one the rehearsal read, so a
        #   mint needs a new rehearsal
        def moved?(entry, live_watermark) = entry["watermark"] != live_watermark

        # @return [void] keeps a would_mint entry for the domain, and forgets any other verdict
        def remember(memo, domain, entry)
          entry ? memo[key(domain)] = entry : memo.delete(key(domain))
        end
      end
    end
  end
end

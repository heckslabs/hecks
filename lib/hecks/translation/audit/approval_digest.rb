require "digest"
require_relative "../../projector/exporter"

module Hecks
  module Translation
    module Audit
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
      module ApprovalDigest
        def edge_digest(edge)
          Digest::SHA256.hexdigest(JSON.generate(Projector::Exporter.translation_hash(edge)))
        end
      end
    end
  end
end

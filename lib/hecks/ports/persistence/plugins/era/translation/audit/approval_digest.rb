require "digest"
require_relative "../../../../../../projector/exporter"

module Hecks
  module Translation
    module Audit
      # The human gate: a compute edge cannot mint until `bin/translation_audit --approve`
      # binds an approval to the edge's content digest and the journal's ordinal at review.
      module ApprovalDigest
        # Fingerprints a parsed translation edge, so an approval lapses when the edge's
        # meaning changes but not when only a comment does.
        #
        # @param edge [Bluebook::Translation] the parsed translation edge
        # @return [String] 64 lowercase hex characters: the SHA-256 of the edge's exported
        #   JSON (`Projector::Exporter.translation_hash`)
        def edge_digest(edge)
          Digest::SHA256.hexdigest(JSON.generate(Projector::Exporter.translation_hash(edge)))
        end
      end
    end
  end
end

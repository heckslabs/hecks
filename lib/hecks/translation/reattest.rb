require "tempfile"
require_relative "../runtime/era_guard"
require_relative "../runtime/registry"
require_relative "../runtime/storage_shape"

module Hecks
  module Translation
    # The question re-attestation must answer before anything else: did
    # the edit change the era's SHAPE, or only its text? Cosmetic edits
    # (comments, whitespace, behavior) re-freeze safely; a shape change
    # would retroactively redefine what era N *meant* for data already
    # written under it, and refuses hard — there is no --accept past
    # this guard.
    #
    # This does not violate minted-once. That prohibition exists so
    # boot-time RECOGNITION never depends on canonicalization stability;
    # this is operator-initiated repair, where a false negative is a
    # loud refusal, never a silent misread.
    module Reattest
      module_function

      def shape_guard!(domain:, ordinal:, text:, stored_hash:, stored_projection: nil)
        bluebook = shadow(text)
        unless bluebook
          raise Runtime::WiringError,
                "cannot re-attest era #{ordinal} of #{domain}: the edited text does not load as a " \
                "bluebook — a held era text is bootable source; restore a loadable text"
        end

        # The stored PROJECTION is the preferred comparison: structural,
        # version-free, and the same mechanism every boot trusts — so
        # this guard never depends on canonicalization stability, and a
        # future canonical-form version cannot make cosmetic edits to
        # old-form eras false-refuse as shape changes. The hash path
        # survives only as a fallback for stores that predate stored
        # projections.
        if stored_projection
          edited = JSON.parse(JSON.generate(Runtime::StorageShape.project(bluebook)))
          return :cosmetic if edited == stored_projection

          raise Runtime::WiringError,
                "cannot re-attest era #{ordinal} of #{domain}: the edit changed the era's SHAPE, not just " \
                "its text — the text no longer projects to the shape frozen for era #{ordinal}. " \
                "Attesting would retroactively redefine what era #{ordinal} meant for data already written " \
                "under it; restore a text with the original shape"
        end
        return :unnamed unless stored_hash

        computed = Runtime::StorageShape.mint_hash(bluebook)
        return :cosmetic if computed == stored_hash

        raise Runtime::WiringError,
              "cannot re-attest era #{ordinal} of #{domain}: the edit changed the era's SHAPE, not just " \
              "its text — its name #{stored_hash[0, Runtime::StorageShape::LABEL_LENGTH]} was minted from " \
              "a different shape (the text now projects to #{computed[0, Runtime::StorageShape::LABEL_LENGTH]}). " \
              "Attesting would retroactively redefine what era #{ordinal} meant for data already written " \
              "under it; restore a text with the original shape"
      end

      def shadow(source)
        file = Tempfile.new(["hecks-reattest-", ".bluebook"])
        file.write(source)
        file.flush
        Runtime::EraGuard.shadow_parse(source, file.path)
      rescue StandardError, SyntaxError
        nil
      ensure
        file&.close!
      end
    end
  end
end

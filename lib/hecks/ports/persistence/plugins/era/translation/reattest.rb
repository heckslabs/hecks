require "tempfile"
require_relative "../era_guard"
require_relative "../../../../../runtime/registry"
require_relative "../storage_shape"

module Hecks
  module Translation
    # Decides whether an edited era text changed the era's shape or only its text.
    # A shape change refuses hard; no --accept flag gets past it.
    module Reattest
      module_function

      # Decides whether an edited era text still projects to the shape the era was frozen
      # with, refusing the edit when it does not.
      #
      # @param domain [String] the domain's name, used in refusal messages
      # @param ordinal [Integer] the era's ordinal, used in refusal messages
      # @param text [String] the held era's bluebook source as it now stands
      # @param stored_hash [String, nil] the era's minted shape hash (SHA-256 hex); nil if unnamed
      # @param stored_projection [Hash{String => Object}, nil] the stored
      #   `Runtime::StorageShape.project` result as parsed JSON; nil when absent
      # @return [Symbol] `:cosmetic` when the shape is unchanged, `:unnamed` when neither a
      #   projection nor a hash is stored
      # @raise [Runtime::WiringError] if `text` does not load, or projects to another shape
      def shape_guard!(domain:, ordinal:, text:, stored_hash:, stored_projection: nil)
        bluebook = shadow(text)
        unless bluebook
          raise Runtime::WiringError,
                "cannot re-attest era #{ordinal} of #{domain}: the edited text does not load as a " \
                "bluebook — a held era text is bootable source; restore a loadable text"
        end

        # The stored projection is compared first: it is version-free, so a new canonical form
        # cannot make a cosmetic edit look like a shape change. The hash is the fallback.
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

      # Parses bluebook source in a scratch registry, through a temporary file that is
      # removed afterwards, without touching the live registry.
      #
      # @param source [String] bluebook source text
      # @return [Bluebook::Chapter, nil] the first bluebook the source declares; nil when it
      #   declares none or fails to parse or load for any reason
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

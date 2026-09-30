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

      # Says how an edited era text stands against the shape the era was frozen with, without
      # refusing anything: the facts `Era.Permit`'s givens hold, and what `shape_guard!` raises on.
      #
      # @param text [String] the held era's bluebook source as it now stands
      # @param stored_hash [String, nil] the era's minted shape hash (SHA-256 hex); nil if unnamed
      # @param stored_projection [Hash{String => Object}, nil] the stored
      #   `Runtime::StorageShape.project` result as parsed JSON; nil when absent
      # @return [Symbol] `:cosmetic` when the shape is unchanged, `:unnamed` when neither a
      #   projection nor a hash is stored, `:changed` when the text projects to another shape,
      #   `:unloadable` when the text does not load as a bluebook
      def verdict(text:, stored_hash:, stored_projection: nil)
        bluebook = shadow(text)
        return :unloadable unless bluebook

        # The stored projection is compared first: it is version-free, so a new canonical form
        # cannot make a cosmetic edit look like a shape change. The hash is the fallback.
        if stored_projection
          edited = JSON.parse(JSON.generate(Runtime::StorageShape.project(bluebook)))
          return edited == stored_projection ? :cosmetic : :changed
        end
        return :unnamed unless stored_hash

        Runtime::StorageShape.mint_hash(bluebook) == stored_hash ? :cosmetic : :changed
      end

      # Refuses an edited era text that projects to another shape than the era froze with.
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
        found = verdict(text: text, stored_hash: stored_hash, stored_projection: stored_projection)
        return found if %i[cosmetic unnamed].include?(found)

        if found == :unloadable
          raise Runtime::WiringError,
                "cannot re-attest era #{ordinal} of #{domain}: the edited text does not load as a " \
                "bluebook — a held era text is bootable source; restore a loadable text"
        end
        raise Runtime::WiringError, changed_shape_message(domain, ordinal, text, stored_hash, stored_projection)
      end

      # The refusal for an edit that changed the era's shape.
      #
      # @return [String] names the minted label when the era was compared by hash
      def changed_shape_message(domain, ordinal, text, stored_hash, stored_projection)
        head = "cannot re-attest era #{ordinal} of #{domain}: the edit changed the era's SHAPE, not just "
        tail = "Attesting would retroactively redefine what era #{ordinal} meant for data already written " \
               "under it; restore a text with the original shape"
        if stored_projection
          return "#{head}its text — the text no longer projects to the shape frozen for era #{ordinal}. #{tail}"
        end

        label = Runtime::StorageShape::LABEL_LENGTH
        "#{head}its text — its name #{stored_hash[0, label]} was minted from a different shape (the text " \
          "now projects to #{Runtime::StorageShape.mint_hash(shadow(text))[0, label]}). #{tail}"
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

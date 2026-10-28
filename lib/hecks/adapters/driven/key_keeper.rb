require_relative "../../runtime/registry"
require_relative "../../ports/key_vault"

module Hecks
  module Adapters
    # The `Keys` port's adapter for a `SubjectKey` (ADR 0142, ADR 0147): has the `key_vault` port
    # issue a subject's key and destroy it, in the boot whose record asked. A vault that cannot
    # raises, and the port records the refusal on the subject's key.
    class KeyKeeper
      # @param registry [Runtime::Registry] the registry the ask comes from, whose vault adapter
      #   holds the keys
      def initialize(registry:)
        @registry = registry
      end

      # Issues a key for the subject a record names. The ask is handed that record's held state, in
      # which the subject is still a one-field value object. The answer names the reference the
      # vault gave, so the answer event carries it on to the policy that records it.
      #
      # @param subject_id [Hash, String] the subject, `{ value: }` as the record holds it
      # @return [Hash{Symbol => String}] `key_reference:`, the vault's opaque reference
      def issue(subject_id:, **)
        { key_reference: Ports::KeyVault.issue(@registry, subject_id: plain(subject_id)) }
      end

      # Destroys the key a subject's record names. The answer names the key that was destroyed, as
      # the state held it, so the answer event carries it on to the policy that records it.
      #
      # @param key_reference [Hash, String] the vault's opaque reference to the key, `{ value: }`
      #   as the record holds it
      # @return [Hash{Symbol => Object}] `key_reference:`, the key that was destroyed
      def destroy(key_reference:, **)
        Ports::KeyVault.destroy(@registry, key_reference: plain(key_reference))
        { key_reference: key_reference }
      end

      private

      def plain(reference) = reference.is_a?(Hash) ? reference[:value] : reference
    end
  end
end

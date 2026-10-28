require_relative "../../runtime/registry"
require_relative "../../ports/key_vault"

module Hecks
  module Adapters
    # The `Keys` port's adapter for a `SubjectKey` (ADR 0142): has the `key_vault` port destroy the
    # key behind a subject's shred request, in the boot whose record asked. A vault that cannot
    # destroy it raises, and the port records the refusal on the subject's key.
    class KeyDestroyer
      # @param registry [Runtime::Registry] the registry the ask comes from, whose vault adapter
      #   holds the key
      def initialize(registry:)
        @registry = registry
      end

      # Destroys the key a subject's record names. The ask is handed that record's held state, in
      # which the reference is still a one-field value object. The answer names the key that was
      # destroyed, as the state held it, so the answer event carries it on to the policy that
      # records the destruction.
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

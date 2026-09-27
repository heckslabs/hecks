require "securerandom"

module Hecks
  module Adapters
    # In-process `key_vault` fulfillment: key material held under opaque references.
    # Not crash-durable; use a KMS or HSM when destruction must survive a restart.
    module InProcessKeyVault
      module_function

      # Mints and stores a fresh symmetric key, returning only an opaque handle to it.
      #
      # @param subject_id [String] the data subject the key is being issued for; held
      #   alongside the key material for {#destroy}'s own bookkeeping, never returned
      # @return [String] an opaque key reference; the key material itself never leaves this
      #   adapter
      def issue(subject_id:)
        key_reference = SecureRandom.uuid
        (@keys ||= {})[key_reference] = { subject_id: subject_id, secret: SecureRandom.hex(32) }
        key_reference
      end

      # Looks up the live key material behind a reference, for encrypting or decrypting.
      #
      # @param key_reference [String] the opaque reference {#issue} returned
      # @return [String, nil] the key's hex-encoded secret, or nil once {#destroy} has run
      def fetch(key_reference) = (@keys ||= {})[key_reference]&.fetch(:secret)

      # Irrevocably deletes a key's material, so {#fetch} can never answer for it again.
      #
      # @param key_reference [String] the opaque reference {#issue} returned
      # @return [Boolean] true when a key was held and is now gone; false when this
      #   reference was already destroyed, or never issued
      def destroy(key_reference:) = !(@keys ||= {}).delete(key_reference).nil? # rubocop:disable Naming/PredicateMethod

      # Resets the vault to empty, forgetting every key this process ever issued.
      #
      # @return [void]
      def reset! = @keys = {}
    end
  end
end

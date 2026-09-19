require "securerandom"

module Hecks
  module Adapters
    # The real `key_vault` fulfillment for a single running process — a
    # table of key material, keyed by an opaque reference never exposed to
    # a bluebook or an event. Cryptoshredding only works if the key
    # genuinely leaves memory when destroyed: `destroy` deletes the Hash
    # entry outright, not merely a flag, so a `fetch` afterward has
    # nothing left to decrypt with.
    #
    # **Not crash-durable** — a process restart loses every key this
    # adapter ever issued, along with every ciphertext under it. A
    # deployment that needs destruction to survive a restart (or to leave
    # a physical-destruction audit trail) backs this port with a real
    # `KMS` or `HSM` instead; this default asks for nothing external to
    # run, the same tradeoff `SecureRandomIdentity` already makes for
    # identity minting.
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

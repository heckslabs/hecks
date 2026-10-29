require_relative "../runtime/registry"

module Hecks
  module Ports
    # A subject's encryption key, one boundary removed from any event or
    # bluebook attribute, so cryptoshredding never exposes key material.
    module KeyVault
      NAME = "key_vault".freeze

      module_function

      # Mints a per-subject key; the key material itself never leaves the bound adapter. The
      # `Keys` port's adapter calls it when a `SubjectKey` asks for a key (ADR 0147).
      def issue(registry, subject_id:) = adapter(registry).issue(subject_id: subject_id)

      # Irrevocably destroys a key; ciphertext under it becomes unrecoverable at once —
      # how a right-to-erasure request is satisfied without rewriting or deleting events.
      def destroy(registry, key_reference:) = adapter(registry).destroy(key_reference: key_reference)

      # Asks for the subject's key to be destroyed by dispatching Shred. The model keeps the
      # order (ADR 0142): Shred only requests, the vault destroys the key, and the record reads
      # `shredded` once the vault has answered. Idempotent: a subject with no key, or one already
      # shredded or being shredded, is left alone and returns false.
      #
      # @return [Boolean] whether a shred was asked for; the record's status says how it ended
      def shred!(dispatcher, domain:, subject_id:)
        provider = dispatcher.registry.provider_of(Bluebook::Capabilities::SUBJECT_KEYS)
        return false unless provider

        record = dispatcher.query(provider.provided_verb(Bluebook::Capabilities::SUBJECT_KEYS, :key_for),
                                  domain: domain, subject_id: subject_id).first
        return false unless record
        return false if %w[shredded shredding].include?(record[:status].to_s)

        shred = provider.provided_verb(Bluebook::Capabilities::SUBJECT_KEYS, :shred)
        dispatcher.dispatch_flat(shred, domain: { value: domain }, subject_id: { value: subject_id })
        true
      end

      # Refuses an ambiguous wiring rather than choosing an adapter arbitrarily.
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }
        return registry.adapter_class(implementations.first.name) if implementations.size == 1

        raise Runtime::WiringError, wiring_refusal(implementations)
      end

      # Words the refusal for a port that resolves to no adapter or to several.
      #
      # @param implementations [Array] the adapters bound to this port
      # @return [String] the error message
      def wiring_refusal(implementations)
        return "no adapter implements the #{NAME} port — nothing can issue or destroy a key" if implementations.empty?

        names = implementations.map(&:name).sort.join(", ")
        "#{implementations.size} adapters implement the #{NAME} port (#{names}) — the runtime will not choose for you"
      end
    end
  end
end

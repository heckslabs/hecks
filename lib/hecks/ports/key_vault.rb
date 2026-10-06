require_relative "../runtime/registry"

module Hecks
  module Ports
    # A subject's encryption key, one boundary removed from any event or
    # bluebook attribute, so cryptoshredding never exposes key material.
    module KeyVault
      NAME = "key_vault".freeze

      module_function

      # Mints a per-subject key; the key material itself never leaves the bound adapter.
      def issue(registry, subject_id:) = adapter(registry).issue(subject_id: subject_id)

      # Irrevocably destroys a key; ciphertext under it becomes unrecoverable at once —
      # how a right-to-erasure request is satisfied without rewriting or deleting events.
      def destroy(registry, key_reference:) = adapter(registry).destroy(key_reference: key_reference)

      # Destroys the subject's key, then dispatches Shred, in that fixed order — never the
      # reverse, so Shred cannot be dispatched before the key is actually gone. Idempotent:
      # a subject with no live key, or one already shredded, is left alone and returns false.
      def shred!(dispatcher, domain:, subject_id:) # rubocop:disable Naming/PredicateMethod
        record = dispatcher.query("Privacy::SubjectKey.ForSubject", domain: domain, subject_id: subject_id).first
        return false unless record
        return false if record[:status].to_s == "shredded"

        destroy(dispatcher.registry, key_reference: record[:key_reference].value)
        dispatcher.dispatch_flat("Privacy::SubjectKey.Shred", domain: { value: domain }, subject_id: { value: subject_id })
        true
      end

      # Refuses an ambiguous wiring rather than choosing an adapter arbitrarily.
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can issue or destroy a key"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(", ")}) — the runtime will not choose for you"
        end
      end
    end
  end
end

require_relative "../runtime/registry"

module Hecks
  module Ports
    # A subject's own encryption key lives here, one boundary removed from
    # any event or bluebook attribute — cryptoshredding depends on the key
    # material never being reachable except through this port's opaque
    # reference (see `Privacy::SubjectKey`, `lib/hecks/framework/bluebook/
    # privacy.bluebook`). Resolved the same way `Ports::IdentityGeneration`
    # resolves its own adapter: one adapter registry-wide answers this
    # port, not a per-aggregate binding.
    module KeyVault
      NAME = "key_vault".freeze

      module_function

      # Mints a fresh per-subject encryption key and hands back an opaque reference to it.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param subject_id [String] the data subject the key is being issued for
      # @return [String] an opaque key reference; the key material itself never leaves the
      #   bound adapter, and is never suitable to store on an event or a bluebook attribute
      def issue(registry, subject_id:) = adapter(registry).issue(subject_id: subject_id)

      # Irrevocably destroys a key that {#issue} already returned a reference for.
      #
      # Ciphertext produced under `key_reference` becomes permanently unrecoverable the
      # moment this returns — the mechanism a right-to-erasure request satisfies without
      # rewriting or deleting any event.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param key_reference [String] the opaque reference {#issue} returned
      # @return [Boolean] true when a live key was destroyed; false when this reference was
      #   already destroyed, or was never issued
      def destroy(registry, key_reference:) = adapter(registry).destroy(key_reference: key_reference)

      # Erases one subject: destroys their key in the vault, then durably records that it
      # happened — in that fixed order, so a caller cannot dispatch `Shred` before the key
      # is actually gone the way calling {#destroy} and `dispatch_flat` separately would
      # allow. `Privacy::SubjectKey.Shred`'s own lifecycle guard (`from: "active"`) still
      # refuses a raw double-dispatch; this is what closes the gap one level up, where the
      # danger isn't a duplicate `Shred` but `Shred` running *before* {#destroy} does.
      #
      # Idempotent: a subject with no live `SubjectKey` record, or one already shredded,
      # is left alone and answered `false` — a retried erasure request never re-destroys
      # an already-gone key or double-dispatches `Shred`.
      #
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted
      #   dispatcher both the lookup query and the `Shred` dispatch run through
      # @param domain [String] the subject's own domain FQN, e.g. `"Lifeadelics::Registration"`
      # @param subject_id [String] the data subject to erase
      # @return [Boolean] true when a live key was found and shredded by this call; false
      #   when no `SubjectKey` record exists for this subject, or it was already shredded
      def shred!(dispatcher, domain:, subject_id:) # rubocop:disable Naming/PredicateMethod
        record = dispatcher.query("Privacy::SubjectKey.ForSubject", domain: domain, subject_id: subject_id).first
        return false unless record
        return false if record[:status].to_s == "shredded"

        destroy(dispatcher.registry, key_reference: record[:key_reference].value)
        dispatcher.dispatch_flat("Privacy::SubjectKey.Shred", domain: { value: domain }, subject_id: { value: subject_id })
        true
      end

      # Finds the single adapter bound to this port, refusing an ambiguous wiring.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @return [Module] the adapter module or class implementing this port
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements this port
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
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end

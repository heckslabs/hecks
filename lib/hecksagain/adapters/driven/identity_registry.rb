module Hecksagain
  module Adapters
    # THE `identity_resolution` PORT, FULFILLED BY THE Identity FRAMEWORK
    # BLUEBOOK — same registry, same boot, so this is a dispatch against
    # records already sitting in the store this adapter is handed, not a
    # bridge to a second runtime. Same reasoning `GovernanceAuthorization`
    # gives for itself, one port over.
    module IdentityRegistry
      module_function

      # `nil` for a pair nothing has linked, the first match otherwise —
      # `ResolvedBy` is a lookup by the exact (issuer, subject) an
      # authenticated token carries, not a listing, so more than one row
      # would mean two links share a pair, which `Link`'s own natural
      # key already prevents by construction.
      def resolve(registry, issuer:, subject:)
        rows = Runtime::Dispatcher.new(registry).query(
          "Identity::ExternalIdentifier.ResolvedBy",
          issuer: { value: issuer.to_s }, subject: { value: subject.to_s }
        )

        rows.first&.fetch(:identity)
      end
    end
  end
end

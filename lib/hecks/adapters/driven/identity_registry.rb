module Hecks
  module Adapters
    # The `identity_resolution` port, fulfilled by the Identity framework
    # bluebook — same registry, same boot, so this is a dispatch against
    # records already sitting in the store this adapter is handed, not a
    # bridge to a second runtime. Same reasoning `GovernanceAuthorization`
    # gives for itself, one port over.
    module IdentityRegistry
      module_function

      # Looks up the id of the identity an authenticated (issuer, subject) pair is linked to,
      # querying the Identity framework bluebook's own `ResolvedBy`.
      #
      # `nil` for a pair nothing has linked, the first match otherwise —
      # `ResolvedBy` is a lookup by the exact (issuer, subject) an
      # authenticated token carries, not a listing, so more than one row
      # would mean two links share a pair, which `Link`'s own natural
      # key already prevents by construction.
      #
      # @param registry [Runtime::Registry] the booted registry, queried for the linked
      #   identity's id
      # @param issuer [String] the OIDC issuer that authenticated the caller, compared as a
      #   String
      # @param subject [String] the OIDC subject the issuer vouches for, compared as a String
      # @return [String, nil] the linked identity's id, or nil if nothing has linked this pair
      def resolve(registry, issuer:, subject:)
        # The resolve verb this registry's declared identity provider names
        # (`provides "identity", resolve:`), never a hard-coded chapter —
        # same declared-not-named shape GovernanceAuthorization already holds.
        provider = registry.bluebooks.values.find { |chapter| chapter.provides?(::Hecks::Bluebook::Capabilities::IDENTITY) }
        verb = provider&.provided_verb(::Hecks::Bluebook::Capabilities::IDENTITY, :resolve) ||
               "Identity::ExternalIdentifier.ResolvedBy"
        rows = Runtime::Dispatcher.new(registry).query(
          verb,
          issuer: { value: issuer.to_s }, subject: { value: subject.to_s }
        )

        rows.first&.fetch(:identity)
      end
    end
  end
end

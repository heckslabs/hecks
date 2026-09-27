module Hecks
  module Adapters
    # The `identity_resolution` port, fulfilled by the Identity framework bluebook
    # through a dispatch on the same registry.
    module IdentityRegistry
      module_function

      # Looks up the id of the identity an authenticated (issuer, subject) pair is linked to,
      # querying the Identity framework bluebook's own `ResolvedBy`.
      #
      # @param registry [Runtime::Registry] the booted registry, queried for the linked
      #   identity's id
      # @param issuer [String] the OIDC issuer that authenticated the caller, compared as a
      #   String
      # @param subject [String] the OIDC subject the issuer vouches for, compared as a String
      # @return [String, nil] the linked identity's id, or nil if nothing has linked this pair
      def resolve(registry, issuer:, subject:)
        # The verb comes from the declared identity provider (`provides "identity", resolve:`).
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

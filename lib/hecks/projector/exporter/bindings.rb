module Hecks
  module Projector
    module Exporter
      # Which bluebook of a registry answers each capability a domain attaches (authorization,
      # membership, identity, and every capability a package declares): a per-deployment binding
      # fact, not part of the declared IR. Each answers `{}` when nothing the domain attaches
      # provides it.
      module Bindings
        # Which bluebook this domain's role checks resolve against
        # (`Registry#authorization_provider_for`); `{}` if none does.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the authorization binding for
        # @return [Hash{Symbol => String, nil}] `:provider` (name), `:grant`, `:assignments` and
        #   `:live_assignments` (provided-verb names), and `:assignment_aggregate`
        #   (`:assignments`' own leading aggregate name); `{}` if nothing this domain attaches provides
        #   authorization
        def authorization(registry, domain_name)
          provider = registry.authorization_provider_for(domain_name)
          return {} unless provider

          verbs = verbs_of(provider, Bluebook::Capabilities::AUTHORIZATION, :grant, :assignments, :live_assignments)
          { provider: provider.name, **verbs, assignment_aggregate: aggregate_of(verbs[:assignments]) }
        end

        # Which bluebook answers "who may sign in" (`Registry#membership_provider_for`),
        # with the membership aggregate named off `admit`; `{}` if none does.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the membership binding for
        # @return [Hash{Symbol => String, nil}] `:provider` (name), `:admit`, `:grant`,
        #   `:people` (qualified verbs), and `:aggregate` (`:admit`'s own leading
        #   aggregate name); `{}` if nothing this domain attaches provides membership
        def membership(registry, domain_name)
          provider = registry.membership_provider_for(domain_name)
          return {} unless provider

          verbs = verbs_of(provider, Bluebook::Capabilities::MEMBERSHIP, :admit, :grant, :people)
          { provider: provider.name, **verbs, aggregate: aggregate_of(verbs[:admit]) }
        end

        # Which bluebook answers "who is this authenticated pair"; `{}` if none does.
        # Breaking in 2.0: Link's reference field is `identity`, never `identity_id`.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the identity binding for
        # @return [Hash{Symbol => String, nil}] `:provider` (name), `:register`, `:link`,
        #   `:resolve` (qualified verbs); `{}` if nothing this domain attaches provides identity
        def identity(registry, domain_name)
          provider = registry.identity_provider_for(domain_name)
          return {} unless provider

          capability = Bluebook::Capabilities::IDENTITY
          {
            provider: provider.name,
            register: provider.provided_verb(capability, :register),
            link:     provider.provided_verb(capability, :link),
            resolve:  provider.provided_verb(capability, :resolve)
          }
        end

        # Every capability a package declares (one the language defines no contract for), as the
        # bluebook that provides it for this domain resolves each key: the qualified verb of a
        # command, query or port operation, the states of a lifecycle mark, or an attribute's
        # `{ attribute:, default: }`. The reader of a capability checks the keys it needs.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the capabilities for
        # @return [Hash{String => Hash{Symbol => Object}}] each capability's name, mapped to
        #   `:provider` (the bluebook's name) and one resolved value per key; `{}` if nothing
        #   loaded declares one
        def provides(registry, domain_name)
          package_capabilities(registry).to_h do |capability|
            provider = registry.vendored_provider_for(domain_name, capability)
            values = provider.provision(capability).transform_values do |verb|
              Bluebook::Capabilities.resolved_value(provider, verb)
            end
            [capability, { provider: provider.name, **values }]
          end
        end

        private

        # The qualified verb `provider` supplies for each of `keys` under `capability`.
        def verbs_of(provider, capability, *keys)
          keys.to_h { |key| [key, provider.provided_verb(capability, key)] }
        end

        # Every capability name a loaded bluebook provides that the language defines no contract for.
        def package_capabilities(registry)
          provided_capabilities(registry).reject { |capability| Bluebook::Capabilities.language_defined?(capability) }
        end

        # Every capability name a loaded bluebook provides, once each, sorted.
        def provided_capabilities(registry)
          chapters = registry.bluebooks.values
          chapters.flat_map { |chapter| chapter.provides.map(&:capability) }.uniq.sort
        end

        # The leading aggregate name of a qualified verb, or `nil` when there is no verb.
        def aggregate_of(verb)
          verb&.split(".")&.first
        end
      end
    end
  end
end

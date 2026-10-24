module Hecks
  module Runtime
    class Registry
      # Finds the loaded chapter that provides a capability for a domain: authorization, identity
      # and membership by name, any other capability through `vendored_provider_for`.
      module Providers
        # The chapter that answers a role check for `domain`: the domain's own chapter, or
        # a chapter its hecksagon attaches, that declares `provides "authorization"`.
        #
        # @param domain [String, Symbol] the domain whose role checks are being resolved
        # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s role
        #   checks, or nil if none does
        def authorization_provider_for(domain)
          names = [domain.to_s, *Array(hecksagon(domain)&.member_chapters)]
          names.filter_map { |name| bluebook(name) }
               .find { |chapter| chapter.provides?(Bluebook::Capabilities::AUTHORIZATION) }
        end

        # Every loaded chapter declaring `provides "authorization"`.
        #
        # @return [Array<Bluebook::Chapter>] every loaded chapter that provides
        #   authorization
        def authorization_providers
          bluebooks.values.select { |chapter| chapter.provides?(Bluebook::Capabilities::AUTHORIZATION) }
        end

        # The chapter that answers "who is this authenticated pair" for `domain`: the
        # domain's own chapter, or a framework member its hecksagon attaches, that
        # declares `provides "identity"`.
        #
        # @param domain [String, Symbol] the domain whose identity chapter is being resolved
        # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s identity
        #   questions, or nil if none does
        def identity_provider_for(domain)
          names = [domain.to_s, *Array(hecksagon(domain)&.member_chapters)]
          attached = names.filter_map { |name| bluebook(name) }
                          .find { |chapter| chapter.provides?(Bluebook::Capabilities::IDENTITY) }
          return attached if attached

          # Falls back to any loaded chapter: a consuming domain often wires Identity as
          # Hecks.hecksagon "Identity" rather than via `attaches`, so it's loaded but
          # not listed on the consumer's own hecksagon.
          bluebooks.values.find { |chapter| chapter.provides?(Bluebook::Capabilities::IDENTITY) }
        end

        # The chapter that answers "who may sign in" for `domain`: the domain's own
        # chapter, a framework member, or a vendored embryonaut bluebook it attaches,
        # that declares `provides "membership"`.
        #
        # Vendored packages are included, since membership ships as a vendored
        # embryonaut_bluebooks chapter, not a framework member.
        #
        # @param domain [String, Symbol] the domain whose sign-in aggregate is being resolved
        # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s membership
        #   questions, or nil if none does
        def membership_provider_for(domain)
          vendored_provider_for(domain, Bluebook::Capabilities::MEMBERSHIP)
        end

        # The first loaded chapter that declares `capability`, whichever domain asks.
        #
        # @param capability [String] a `Bluebook::Capabilities` name
        # @return [Bluebook::Chapter, nil] the providing chapter, or nil if none loaded does
        def provider_of(capability) = bluebooks.values.find { |chapter| chapter.provides?(capability) }

        # The chapter that provides `capability` for `domain`: the domain's own chapter,
        # a framework member its hecksagon attaches, or a vendored embryonaut bluebook
        # it attaches, that declares it.
        #
        # Falls back to any loaded chapter, since a consuming domain often wires a
        # vendored chapter as its own `Hecks.hecksagon "Name"` rather than via
        # `attaches ... from: :vendor`, so it's loaded but not listed on the consumer's hecksagon.
        #
        # @param domain [String, Symbol] the domain the provider is resolved for
        # @param capability [String] the capability's name: `Bluebook::Capabilities::MEMBERSHIP`,
        #   or one a package declares
        # @return [Bluebook::Chapter, nil] the providing chapter, or nil if none loaded does
        def vendored_provider_for(domain, capability)
          hecksagon = hecksagon(domain)
          names = [domain.to_s, *Array(hecksagon&.member_chapters)]
          attached = names.filter_map { |name| bluebook(name) }
                          .find { |chapter| chapter.provides?(capability) }
          return attached if attached

          bluebooks.values.find { |chapter| chapter.provides?(capability) }
        end
      end
    end
  end
end

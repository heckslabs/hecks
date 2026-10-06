module Hecks
  module Runtime
    class Registry
      # Finds the loaded chapter that provides a capability for a domain: authorization, identity,
      # membership, newsletters, registrations and payments.
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

        # The chapter that answers the guest newsletter signup for `domain`: the domain's
        # own chapter, a framework member, or a vendored embryonaut bluebook it attaches,
        # that declares `provides "newsletter"`.
        #
        # @param domain [String, Symbol] the domain whose newsletter chapter is being resolved
        # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s newsletter
        #   signup, or nil if none does
        def newsletter_provider_for(domain)
          vendored_provider_for(domain, Bluebook::Capabilities::NEWSLETTER)
        end

        # The chapter that answers sending a newsletter issue for `domain` —
        # resolved the same way as `newsletter_provider_for`, by what it
        # declares (`provides "newsletter_issues"`). Nil when none does.
        #
        # @param domain [String, Symbol] the domain whose issue-sending chapter is being resolved
        # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s issue sending,
        #   or nil if none does
        def newsletter_issues_provider_for(domain)
          vendored_provider_for(domain, Bluebook::Capabilities::NEWSLETTER_ISSUES)
        end

        # The chapter that answers scheduling sessions and registrations for `domain`,
        # resolved the same way as `payments_provider_for`, by declaring `provides "registrations"`.
        #
        # @param domain [String, Symbol] the domain whose registrations chapter is being resolved
        # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s registrations,
        #   or nil if none does
        def registrations_provider_for(domain)
          vendored_provider_for(domain, Bluebook::Capabilities::REGISTRATIONS)
        end

        # The chapter that owns the business's payment-processor connection for
        # `domain` — resolved by what it declares (`provides "payment_connection"`).
        # Nil when none does.
        #
        # @param domain [String, Symbol] the domain whose payment-connection chapter is
        #   being resolved
        # @return [Bluebook::Chapter, nil] the chapter that owns `domain`'s payment connection,
        #   or nil if none does
        def payment_connection_provider_for(domain)
          vendored_provider_for(domain, Bluebook::Capabilities::PAYMENT_CONNECTION)
        end

        # The chapter that takes payments for `domain`: the domain's own chapter, a
        # framework member, or a vendored embryonaut bluebook it attaches, that
        # declares `provides "payments"`.
        #
        # @param domain [String, Symbol] the domain whose payments chapter is being resolved
        # @return [Bluebook::Chapter, nil] the chapter that takes `domain`'s payments, or nil
        #   if none does
        def payments_provider_for(domain)
          vendored_provider_for(domain, Bluebook::Capabilities::PAYMENTS)
        end

        # The chapter that provides `capability` for `domain`: the domain's own chapter,
        # a framework member its hecksagon attaches, or a vendored embryonaut bluebook
        # it attaches, that declares it.
        #
        # Falls back to any loaded chapter, since a consuming domain often wires a
        # vendored chapter as its own `Hecks.hecksagon "Name"` rather than via
        # `attaches ... from: :vendor`, so it's loaded but not listed on the consumer's hecksagon.
        #
        # @param domain [String, Symbol] the domain the provider is resolved for
        # @param capability [String] the capability's name, such as
        #   `Bluebook::Capabilities::MEMBERSHIP`
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

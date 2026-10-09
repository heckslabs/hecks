require_relative "capability_values"

module Hecks
  module Projector
    module Exporter
      # Which chapter of a registry answers each capability a domain attaches (authorization,
      # membership, identity, newsletter, registrations, payments): a per-deployment binding fact,
      # not part of the declared IR. Each answers `{}` when nothing the domain attaches provides it.
      module Bindings
        include CapabilityValues

        # Which chapter this domain's role checks resolve against
        # (`Registry#authorization_provider_for`); `{}` if none does.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the authorization binding for
        # @return [Hash{Symbol => String, nil}] `:provider` (name), `:grant`, `:assignments`
        #   (both provided-verb names), and `:assignment_aggregate` (`:assignments`' own
        #   leading aggregate name); `{}` if nothing this domain attaches provides
        #   authorization
        def authorization(registry, domain_name)
          provider = registry.authorization_provider_for(domain_name)
          return {} unless provider

          capability = Bluebook::Capabilities::AUTHORIZATION
          assignments = provider.provided_verb(capability, :assignments)
          {
            provider:             provider.name,
            grant:                provider.provided_verb(capability, :grant),
            assignments:          assignments,
            assignment_aggregate: aggregate_of(assignments)
          }
        end

        # Which chapter answers "who may sign in" (`Registry#membership_provider_for`),
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

        # Which chapter answers "who is this authenticated pair"; `{}` if none does.
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

        # Which chapter answers the guest newsletter signup
        # (`Registry#newsletter_provider_for`); `{}` if none does.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the newsletter binding for
        # @return [Hash{Symbol => String, nil}] `:provider` (name), `:subscribe`, `:add_name`,
        #   `:confirm`, `:unsubscribe` (qualified verbs), `:aggregate` (`:subscribe`'s own
        #   leading qualified aggregate name) and, when declared, `:awaiting_confirmation`,
        #   `:receives_issues` and `:left` (the states of the lifecycle marks they name) and
        #   `:confirm_window` and `:unsubscribe_window` (seconds); `{}` if nothing this domain
        #   attaches provides newsletter
        def newsletter(registry, domain_name)
          provider = registry.newsletter_provider_for(domain_name)
          return {} unless provider

          verbs = verbs_of(provider, Bluebook::Capabilities::NEWSLETTER,
                           :subscribe, :add_name, :confirm, :unsubscribe)
          { provider: provider.name, **verbs, aggregate: aggregate_of(verbs[:subscribe]),
            **all_marked_states(provider, Bluebook::Capabilities::NEWSLETTER),
            **all_durations(provider, Bluebook::Capabilities::NEWSLETTER) }
        end

        # Which chapter answers sending a newsletter issue
        # (`Registry#newsletter_issues_provider_for`); `{}` if none does.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the issue-sending binding for
        # @return [Hash{Symbol => String, nil}] `:provider` (name), `:send_issue`,
        #   `:record_delivery` (qualified verbs), `:issue_aggregate` and `:delivery_aggregate`
        #   (each verb's own leading qualified aggregate name); `{}` if nothing this domain
        #   attaches provides newsletter_issues
        def newsletter_issues(registry, domain_name)
          provider = registry.newsletter_issues_provider_for(domain_name)
          return {} unless provider

          verbs = verbs_of(provider, Bluebook::Capabilities::NEWSLETTER_ISSUES, :send_issue, :record_delivery)
          { provider: provider.name, **verbs,
            **aggregates_of(verbs, issue_aggregate: :send_issue, delivery_aggregate: :record_delivery) }
        end

        # Which chapter answers scheduling sessions and taking registrations
        # (`Registry#registrations_provider_for`); `{}` if none does.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the registrations binding for
        # @return [Hash{Symbol => String, nil}] `:provider` (name), `:schedule`, `:request`
        #   (qualified verbs), `:event_aggregate` and `:registration_aggregate` (each verb's own
        #   leading qualified aggregate name); `{}` if nothing this domain attaches provides
        #   registrations
        def registrations(registry, domain_name)
          provider = registry.registrations_provider_for(domain_name)
          return {} unless provider

          verbs = verbs_of(provider, Bluebook::Capabilities::REGISTRATIONS, :schedule, :request)
          { provider: provider.name, **verbs,
            **aggregates_of(verbs, event_aggregate: :schedule, registration_aggregate: :request) }
        end

        # Which chapter owns the payment-processor connection
        # (`Registry#payment_connection_provider_for`); `{}` if none does.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the payment-connection binding for
        # @return [Hash{Symbol => String, nil}] `:provider` (name), one qualified verb per
        #   contract key (`:connect`, `:reconnect`, `:disconnect`, `:suspend`, `:resume`,
        #   `:enable`, `:disable`) and `:aggregate` (`:connect`'s own leading qualified
        #   aggregate name); `{}` if nothing this domain attaches provides payment_connection
        def payment_connection(registry, domain_name)
          provider = registry.payment_connection_provider_for(domain_name)
          return {} unless provider

          capability = Bluebook::Capabilities::PAYMENT_CONNECTION
          verbs = verbs_of(provider, capability, *Bluebook::Capabilities::CONTRACTS.fetch(capability).keys)
          { provider: provider.name, **verbs, aggregate: aggregate_of(verbs[:connect]) }
        end

        # Which chapter takes payments (`Registry#payments_provider_for`);
        # `{}` if none does.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the payments binding for
        # @return [Hash{Symbol => String, nil}] `:provider` (name), `:initiate`, `:succeeded`,
        #   `:failed` (qualified verbs), `:aggregate` (`:initiate`'s own leading qualified
        #   aggregate name) and, when declared, `:holds_seat` (the states of the lifecycle mark
        #   it names); `{}` if nothing this domain attaches provides payments
        def payments(registry, domain_name)
          provider = registry.payments_provider_for(domain_name)
          return {} unless provider

          verbs = verbs_of(provider, Bluebook::Capabilities::PAYMENTS, :initiate, :succeeded, :failed)
          { provider: provider.name, **verbs, aggregate: aggregate_of(verbs[:initiate]),
            **marked_states(provider, Bluebook::Capabilities::PAYMENTS, :holds_seat) }
        end

        # Which chapter owns the checkout boundary (`Registry#checkout_provider_for`); `{}` if
        # none does.
        #
        # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
        # @param domain_name [String] the domain to export the checkout binding for
        # @return [Hash{Symbol => Object}] `:provider` (name) and, when declared,
        #   `:webhook_tolerance` and `:session_hold` (whole seconds); `{}` if nothing this
        #   domain attaches provides checkout
        def checkout(registry, domain_name)
          provider = registry.checkout_provider_for(domain_name)
          return {} unless provider

          { provider: provider.name, **all_durations(provider, Bluebook::Capabilities::CHECKOUT) }
        end

        private

        # The qualified verb `provider` supplies for each of `keys` under `capability`.
        def verbs_of(provider, capability, *keys)
          keys.to_h { |key| [key, provider.provided_verb(capability, key)] }
        end

        # Each name in `names` mapped to the leading aggregate of the verb its key names in `verbs`.
        def aggregates_of(verbs, names)
          names.transform_values { |key| aggregate_of(verbs[key]) }
        end

        # The leading aggregate name of a qualified verb, or `nil` when there is no verb.
        def aggregate_of(verb)
          verb&.split(".")&.first
        end
      end
    end
  end
end

require "json"
require_relative "../ports/persistence"

module Hecks
  module Projector
    # Registry-wide serialization to Hash/JSON, for the canonical bluebook IR,
    # binding facts, and translation edges (declared and compiled).
    module Exporter
      module_function

      # Exports every booted bluebook's own canonical IR.
      #
      # @param registry [Runtime::Registry] the booted registry to export
      # @return [Hash{String => Hash}] each domain name, mapped to its bluebook's `to_h`
      def call(registry)
        registry.bluebooks.transform_values(&:to_h)
      end

      # Exports every booted bluebook's own canonical IR as JSON.
      #
      # @param registry [Runtime::Registry] the booted registry to export
      # @return [String] `call`'s output, as pretty-printed JSON
      def json(registry)
        JSON.pretty_generate(call(registry))
      end

      # Whether each aggregate is bound to a lineage-capable adapter — a per-deployment
      # binding fact, not part of the declared IR `call` exports (ADR 0001).
      # Empty when the era persistence plugin isn't loaded, rather than raising.
      #
      # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
      # @param domain_name [String] the domain to check era-adapter lineage capability for
      # @return [Hash{Symbol => Array<Hash{Symbol => String}>}] `:capable_aggregates`,
      #   each a `:name`/`:storage_name` Hash; empty when the era plugin is unloaded or
      #   nothing this domain binds is lineage-capable
      # @raise [KeyError] if `domain_name` is not a loaded domain
      def lineage(registry, domain_name)
        return { capable_aggregates: [] } unless Ports::Persistence.plugin?(:era)

        bluebook = registry.bluebooks.fetch(domain_name)
        capable = bluebook.aggregates.select do |aggregate|
          adapter_name = Runtime::EraCheck.adapter_for(registry, domain_name, aggregate)
          Runtime::EraCheck.lineage_capable?(registry, adapter_name)
        end

        { capable_aggregates: capable.map { |aggregate| { name: aggregate.name, storage_name: aggregate.storage_name } } }
      end

      # Every aggregate's declared persistence adapter (`persisted_by`) — a binding
      # fact like `lineage`, not part of the declared IR `call` exports (ADR 0001).
      #
      # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
      # @param domain_name [String] the domain to export persistence bindings for
      # @return [Hash{Symbol => Array<Hash{Symbol => Object}>}] `:aggregates`, each a
      #   `:name`/`:storage_name`/`:adapter` Hash
      # @raise [KeyError] if `domain_name` is not a loaded domain
      # @raise [Runtime::WiringError] if an aggregate has no authoritative bind, more
      #   than one, or a bind with a role this port does not support
      def persistence(registry, domain_name)
        bluebook = registry.bluebooks.fetch(domain_name)
        aggregates = bluebook.aggregates.map do |aggregate|
          adapter = Ports::Persistence::BindingPolicy.resolve(registry, domain_name, aggregate).adapter
          { name: aggregate.name, storage_name: aggregate.storage_name, adapter: adapter }
        end

        { aggregates: aggregates }
      end

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
          assignment_aggregate: assignments&.split(".")&.first
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

        capability = Bluebook::Capabilities::MEMBERSHIP
        admit = provider.provided_verb(capability, :admit)
        {
          provider:  provider.name,
          admit:     admit,
          grant:     provider.provided_verb(capability, :grant),
          people:    provider.provided_verb(capability, :people),
          aggregate: admit&.split(".")&.first
        }
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
      #   `:confirm`, `:unsubscribe` (qualified verbs), and `:aggregate` (`:subscribe`'s own
      #   leading qualified aggregate name); `{}` if nothing this domain attaches provides
      #   newsletter
      def newsletter(registry, domain_name)
        provider = registry.newsletter_provider_for(domain_name)
        return {} unless provider

        capability = Bluebook::Capabilities::NEWSLETTER
        subscribe = provider.provided_verb(capability, :subscribe)
        {
          provider:    provider.name,
          subscribe:   subscribe,
          add_name:    provider.provided_verb(capability, :add_name),
          confirm:     provider.provided_verb(capability, :confirm),
          unsubscribe: provider.provided_verb(capability, :unsubscribe),
          aggregate:   subscribe&.split(".")&.first
        }
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

        capability = Bluebook::Capabilities::NEWSLETTER_ISSUES
        send_issue = provider.provided_verb(capability, :send_issue)
        record_delivery = provider.provided_verb(capability, :record_delivery)
        {
          provider:           provider.name,
          send_issue:         send_issue,
          record_delivery:    record_delivery,
          issue_aggregate:    send_issue&.split(".")&.first,
          delivery_aggregate: record_delivery&.split(".")&.first
        }
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

        capability = Bluebook::Capabilities::REGISTRATIONS
        schedule = provider.provided_verb(capability, :schedule)
        request = provider.provided_verb(capability, :request)
        {
          provider:               provider.name,
          schedule:               schedule,
          request:                request,
          event_aggregate:        schedule&.split(".")&.first,
          registration_aggregate: request&.split(".")&.first
        }
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
        verbs = Bluebook::Capabilities::CONTRACTS.fetch(capability).keys.to_h { |key| [key, provider.provided_verb(capability, key)] }
        { provider: provider.name, **verbs, aggregate: verbs[:connect]&.split(".")&.first }
      end

      # Which chapter takes payments (`Registry#payments_provider_for`);
      # `{}` if none does.
      #
      # @param registry [Runtime::Registry] the booted registry `domain_name` is loaded in
      # @param domain_name [String] the domain to export the payments binding for
      # @return [Hash{Symbol => String, nil}] `:provider` (name), `:initiate`, `:succeeded`,
      #   `:failed` (qualified verbs), and `:aggregate` (`:initiate`'s own leading qualified
      #   aggregate name); `{}` if nothing this domain attaches provides payments
      def payments(registry, domain_name)
        provider = registry.payments_provider_for(domain_name)
        return {} unless provider

        capability = Bluebook::Capabilities::PAYMENTS
        initiate = provider.provided_verb(capability, :initiate)
        {
          provider:  provider.name,
          initiate:  initiate,
          succeeded: provider.provided_verb(capability, :succeeded),
          failed:    provider.provided_verb(capability, :failed),
          aggregate: initiate&.split(".")&.first
        }
      end

      # Every registered translation, with each aggregate's precompiled SQL attached —
      # `values:` serializes as `[key, value]` pairs since a convert's keys are typed.
      #
      # @param registry [Runtime::Registry] the booted registry to export translations from
      # @return [Array<Hash>] every registered translation, as `compiled_translation_hash`
      #   builds
      def translations(registry)
        registry.translations.map { |translation| compiled_translation_hash(translation) }
      end

      # Exports one translation, its aggregates' compiled SQL included.
      #
      # @param translation [Bluebook::Translation] the translation to export
      # @return [Hash{Symbol => Object}] `:domain` (String), `:from`/`:to` (the era
      #   identifiers as declared), `:retired` (`Array<String>`), and `:aggregates`
      #   (each `compiled_translation_aggregate`'s own Hash)
      def compiled_translation_hash(translation)
        {
          domain:     translation.domain,
          from:       translation.from,
          to:         translation.to,
          retired:    translation.retired,
          aggregates: translation.aggregates.map { |aggregate| compiled_translation_aggregate(aggregate) }
        }
      end

      # Exports every registered translation as JSON.
      #
      # @param registry [Runtime::Registry] the booted registry to export translations from
      # @return [String] `translations`' output, as pretty-printed JSON
      def translations_json(registry)
        JSON.pretty_generate(translations(registry))
      end

      # The digest-relevant shape `ApprovalDigest.edge_digest` hashes — declared rules only,
      # never the compiled SQL, so a compiler-output change can't invalidate an approval.
      #
      # @param translation [Bluebook::Translation] the translation to digest
      # @return [Hash{Symbol => Object}] `:domain` (String), `:from`/`:to` (the era
      #   identifiers as declared), `:retired` (`Array<String>`), and `:aggregates`
      #   (each `translation_aggregate`'s own Hash)
      def translation_hash(translation)
        {
          domain:     translation.domain,
          from:       translation.from,
          to:         translation.to,
          retired:    translation.retired,
          aggregates: translation.aggregates.map { |aggregate| translation_aggregate(aggregate) }
        }
      end

      # Digests one aggregate's own declared translation rules.
      #
      # @param aggregate [Bluebook::TranslationAggregate] the aggregate's own
      #   translation rules to digest
      # @return [Hash{Symbol => Object}] `:name` (String), `:was` (String, nil),
      #   `:renames` (`Hash{String => String}`), `:moves`/`:converts`/`:retypes`/
      #   `:computes`/`:rekeys`/`:backfills` (each an `Array<Hash>`), `:drops`
      #   (`Array<String>`)
      def translation_aggregate(aggregate)
        {
          name:      aggregate.name,
          was:       aggregate.was,
          renames:   aggregate.renames.transform_keys(&:to_s).transform_values(&:to_s),
          moves:     aggregate.moves.map { |move| { from: move.from, to: move.to } },
          converts:  aggregate.converts.map do |convert|
            { from: convert.from, to: convert.to, values: convert.values.map { |key, value| [key, value] } }
          end,
          drops:     aggregate.drops.map(&:to_s),
          retypes:   aggregate.retypes.map { |retype| { from: retype.from, to: retype.to } },
          computes:  aggregate.computes.map { |compute| { from: compute.from, to: compute.to, sql: compute.sql } },
          # `rekeys`/`backfills` are digest-relevant too — a rekey with no compute
          # would otherwise collide with any other, letting its SQL change silently
          # invalidate nothing.
          rekeys:    aggregate.rekeys.map { |rekey| { sql: rekey.sql } },
          backfills: aggregate.backfills.map { |backfill| { name: backfill.name.to_s, default: backfill.default } }
        }
      end

      # `translation_aggregate`'s fields, plus precompiled SQL from the same
      # `Translation::RuleCompiler` mint time uses (ADR 0033 governs its fallback).
      #
      # @param aggregate [Bluebook::TranslationAggregate] the aggregate's own
      #   translation rules to compile and export
      # @return [Hash{Symbol => Object}] `translation_aggregate`'s own Hash, plus
      #   `:compiled_state_expression` (String) and `:compiled_id_expression`
      #   (String, nil) when the era persistence plugin is loaded
      def compiled_translation_aggregate(aggregate)
        return translation_aggregate(aggregate) unless Ports::Persistence.plugin?(:era)

        translation_aggregate(aggregate).merge(
          compiled_state_expression: Translation::RuleCompiler.compile_rules(aggregate),
          compiled_id_expression:    (if Translation::RuleCompiler.rekeyed?(aggregate)
                                        Translation::RuleCompiler.compile_id_expression(aggregate)
                                      end)
        )
      end
    end
  end
end

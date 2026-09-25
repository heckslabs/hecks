require "json"
require_relative "../ports/persistence"

module Hecks
  module Projector
    # Registry-wide serialization to Hash/JSON: bluebook IR
    # (`call`/`json`), era-adapter lineage-capability flags (`lineage`),
    # and translation edges in both their digest-relevant declared shape
    # (`translation_hash`, what ApprovalDigest hashes) and their
    # consumer-ready compiled shape with precompiled SQL attached
    # (`translations`/`compiled_translation_aggregate`). Read directly by
    # bin/ir, bin/project_rust, and the translation/audit approval digest.
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

      # A binding fact, deliberately not folded into `call`/`bluebook.to_h`
      # above — the canonical IR is runtime-independent by design (ADR
      # 0001: it describes what a bluebook declares, never which adapter
      # a deployment happens to bind it to), and "is this aggregate bound
      # to a lineage-capable adapter" is exactly the kind of fact that
      # answer can change per-deployment without the bluebook's own shape
      # changing at all. Consumers that need it (bin/project_rust's own
      # `ir.json` sidecar, rust/host's runtime era-aware seed overlay —
      # dispatch.rs) merge this in as a separate top-level key, the same
      # way `translations` already sits beside `call`'s output rather than
      # inside it.
      #
      # Reuses `Runtime::EraCheck`'s own capability predicates rather than
      # re-deriving them — the boot-time gate and this export must never
      # answer differently for the same aggregate.
      #
      # ADR 0033 — `Runtime::EraCheck` lives in the (optional) era
      # persistence plugin now; unloaded, this answers exactly what it
      # already answers for a domain with nothing lineage-capable bound —
      # `capable_aggregates: []` — rather than raising on an undefined
      # constant.
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

      # A binding fact, same shape/reasoning as `lineage` above: every
      # aggregate's declared persistence adapter name (`persisted_by`),
      # not part of the canonical bluebook shape `call` exports (ADR
      # 0001 — the IR describes what's declared, never which adapter a
      # deployment binds it to). Unlike `lineage`, this needs no era
      # plugin — `BindingPolicy` is core, always loaded — and covers
      # every aggregate, not just lineage-capable ones: `rust/host`
      # (`ir.rs`'s own `refuse_unsupported_persistence_adapters`) reads
      # this to refuse loudly, at boot, against a domain bound to an
      # adapter it has no backend for (Heki, Memory, Sqlite, D1,
      # LocalStorage — `rust/host` understands only Postgres/PostgresEra
      # today), rather than silently building up a second, disjoint
      # history nothing but Rust ever reads while the real state stays
      # wherever its own adapter actually wrote it.
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

      # A binding fact, same shape/reasoning as `lineage`/`persistence`
      # above: which chapter this domain's role checks resolve against
      # (`Registry#authorization_provider_for` — the domain's own chapter
      # or a framework member it attaches that declares `provides
      # "authorization"`), with that chapter's declared verbs qualified.
      # `rust/host` (auth.rs) reads this instead of naming Governance.
      # `{}` when nothing this domain attaches provides authorization.
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

      # Same seam as `authorization` — which chapter answers "who may
      # sign in" (`Registry#membership_provider_for`), with its declared
      # verbs qualified and the membership aggregate named off `admit`.
      # rust/host reads this instead of HECKS_MEMBERSHIP_AGGREGATE.
      # `{}` when nothing this domain attaches provides membership.
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

      # Same seam as `authorization` — which chapter answers "who is this
      # authenticated pair" (`Registry#identity_provider_for`), with its
      # declared verbs qualified. rust/host reads this instead of naming
      # Identity::Identity.Register / ExternalIdentifier.Link. `{}` when
      # nothing this domain attaches provides identity. Breaking in 2.0:
      # Link's reference field is `identity`, never `identity_id`.
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

      # Same seam as `membership` — which chapter answers the guest
      # newsletter signup (`Registry#newsletter_provider_for`), with its
      # declared verbs qualified and the subscribing aggregate named off
      # `subscribe`. rust/host reads this instead of naming
      # Newsletter::Subscriber.Subscribe and friends. `{}` when nothing
      # this domain attaches provides newsletter.
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
      # (`Registry#newsletter_issues_provider_for`), with its declared verbs
      # qualified and the issue and delivery aggregates named off them.
      # rust/host's send route reads this instead of naming
      # Newsletter::Issue.Send and Newsletter::Delivery.Record. `{}` when
      # nothing this domain attaches provides newsletter_issues.
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

      # Same seam as `newsletter` — which chapter takes payments
      # (`Registry#payments_provider_for`), with its declared verbs
      # qualified and the paying aggregate named off `initiate`. rust/host
      # reads this instead of naming Payments::Payment.Initiate and the
      # PaymentGateway operations. `{}` when nothing this domain attaches
      # provides payments.
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

      # Translation IR, always as an array, with each aggregate's
      # precompiled SQL attached (`compiled_translation_aggregate`) —
      # this is the export a consumer embeds (`ir.json`'s `translations`
      # key), never the bare digest-relevant shape `edge_digest` hashes
      # (see that method's own header for why the two must stay
      # separate). `values:` tables serialize as `[key, value]` pairs,
      # never an object, because JSON object keys are always strings and
      # a convert's keys are typed.
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

      # The digest-relevant shape — `ApprovalDigest.edge_digest` hashes
      # exactly this, and only this, for exactly the reason `compiled_
      # translation_aggregate` below must never be used for that
      # purpose: a digest bound to the compiled SQL, not just the
      # declared rules, would invalidate an existing human approval the
      # moment `Translation::RuleCompiler`'s own output format changed
      # for any reason — a compiler refactor, a cosmetic SQL-formatting
      # change — even when the declared rules an approver actually
      # reviewed never changed at all. The approval binds to what was
      # declared, not to what a particular compiler build happened to
      # emit from it.
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
          # **`rekeys`/`backfills` are digest-relevant too.** Without them, an
          # edge carrying only a rekey (no compute) would bind its approval
          # to nothing rekey-specific: any two rekey edges with otherwise-
          # identical renames/moves/converts/drops/retypes/computes would
          # produce the same digest regardless of what their `rekey sql:`
          # actually said, letting a rekey's own SQL change without
          # invalidating an existing approval. Same reasoning covers
          # `backfills`.
          rekeys:    aggregate.rekeys.map { |rekey| { sql: rekey.sql } },
          backfills: aggregate.backfills.map { |backfill| { name: backfill.name.to_s, default: backfill.default } }
        }
      end

      # The export shape — `translation_aggregate`'s own digest-relevant
      # fields, plus the precompiled SQL (`compiled_state_expression`/
      # `compiled_id_expression`) a consumer embedding this JSON
      # (rust/host's own boot-time mint) needs to execute the edge
      # without compiling SQL itself. The same call head_compiler.rb's
      # own `compile_rules(declared)`/`id_case(guard, declared)` make at
      # mint time, run here once at build/export time instead —
      # `Translation::RuleCompiler` is the one place this expression is
      # built, called from both here and from head_compiler.rb's real
      # per-mint assembly, so a consumer gets Ruby's own compiler's
      # output verbatim, never a second, independently-authored SQL
      # compiler that could drift from this one. `compiled_id_
      # expression` is nil unless this edge rekeys — the bare
      # `aggregate_id` passthrough head_compiler.rb itself falls back to
      # for the overwhelming common case.
      # ADR 0033 — `Translation::RuleCompiler` lives in the era plugin;
      # unloaded, there is nothing that can compile this SQL, so this
      # falls back to the bare declared fields (`translation_aggregate`
      # alone) rather than raising on an undefined constant. A consumer
      # embedding this JSON without the era plugin loaded gets the same
      # declared-rules shape, just without precompiled SQL to execute —
      # consistent with there being no mint/audit machinery to run it
      # against either.
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

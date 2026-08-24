require_relative "../ports/persistence/binding_policy"

module Hecks
  module Runtime
    # The capability idiom for MULTI-TENANT hosting — mirrors EraCheck's
    # own `lineage_capable?`, one level over. An adapter answers
    # `tenant_capable?` with true when its OWN instances genuinely
    # isolate one boot's data from another's, given each tenant is its
    # own separate `Runtime.boot` call (its own Registry, its own
    # Dispatcher, its own adapter instances) rather than one shared
    # process switching connections mid-dispatch.
    #
    # THAT LAST PART IS THE FINDING THIS MODULE ENCODES. The project
    # register (Bluebook::ProjectRegister) already resolves an address's
    # REALM to a DISPATCHER at registration time — Router#resolve looks
    # the FQN up in one flat table keyed by realm::domain::aggregate.verb,
    # and each entry already carries its OWN dispatcher from its OWN
    # boot. So "which tenant" is decided ONCE, at boot/registration time
    # (which of possibly many boots of the same directory a request's
    # realm resolves to), never per-dispatch inside a shared registry.
    # No ambient thread-local "current tenant" is needed, and no
    # connection cache is needed beyond what booting-once-per-tenant
    # already gives for free — each tenant's own PostgresEra instance
    # IS its own connection, held for the life of that boot.
    #
    # So `tenant_capable?` asks a narrower question than it might sound:
    # not "can this adapter switch tenants," but "does booting this
    # adapter twice, with different settings, for the same directory,
    # actually keep the two boots' data apart." Memory answers true
    # trivially — a `@records` Hash is a plain instance variable, and
    # two `Runtime.boot` calls build two entirely separate Registry
    # objects, so two Memory adapter instances never share state by
    # construction. PostgresEra answers true because its own `schema:`
    # setting (already built, already the Storehouse mechanism) puts
    # each boot's tables in their own Postgres schema via `SET
    # search_path` — proven for real, not assumed, by
    # tenant_isolation_spec.rb. Plain Postgres (no schema story) and D1
    # (no schema-equivalent at all — see world.bluebook's own comment on
    # the lifeadelics D1 tradeoff) answer false, or don't answer at all,
    # which this module treats identically to false.
    module TenantCheck
      module_function

      # A domain is safe to boot for MORE THAN ONE TENANT only if every
      # aggregate's resolved persistence adapter is tenant_capable? — one
      # ungoverned adapter sharing state across two tenant boots is a
      # real data leak, not a theoretical one, so this is checked before
      # a second tenant boot of the same directory is trusted, the same
      # severity EraCheck/refuse_ungoverned_roles! already hold their
      # own gates to.
      def refuse_unless_tenant_capable!(registry, domain)
        bluebook = registry.bluebook(domain)
        return unless bluebook

        offender = bluebook.aggregates.find do |aggregate|
          adapter_name = Ports::Persistence::BindingPolicy.resolve(registry, domain, aggregate).adapter
          !tenant_capable?(registry, adapter_name)
        end
        return unless offender

        adapter_name = Ports::Persistence::BindingPolicy.resolve(registry, domain, offender).adapter
        raise WiringError,
              "#{domain}::#{offender.hecks_name} is bound to #{adapter_name}, which is not " \
              "tenant_capable? — booting #{domain} for more than one tenant would share " \
              "#{adapter_name}'s own storage across tenants that must never see each other's data. " \
              "Bind a tenant-capable adapter (Memory, PostgresEra with its own schema: per tenant), " \
              "or keep #{domain} single-tenant."
      end

      # The capability idiom itself — an adapter CLASS that answers
      # tenant_capable? with true keeps two boots' data apart by
      # construction (Memory) or by an explicit per-boot isolation
      # setting (PostgresEra's schema:). Same defensive shape
      # EraCheck#lineage_capable? already uses: a class that doesn't
      # respond at all is false, not an error.
      def tenant_capable?(registry, adapter_name)
        adapter_class = registry.adapters[adapter_name] && registry.adapter_class(adapter_name)
        adapter_class.respond_to?(:tenant_capable?) && adapter_class.tenant_capable?
      rescue StandardError
        false
      end
    end
  end
end

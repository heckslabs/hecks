require_relative "../ports/persistence/binding_policy"
require_relative "best_effort"

module Hecks
  module Runtime
    # The capability idiom for multi-tenant hosting — mirrors EraCheck's
    # own `lineage_capable?`, one level over.
    module TenantCheck
      module_function

      # One ungoverned adapter sharing state across two tenant boots is a
      # real data leak, so this is checked with the same severity
      # EraCheck/refuse_ungoverned_roles! already hold their own gates to.
      def refuse_unless_tenant_capable!(registry, domain)
        bluebook = registry.bluebook(domain)
        return unless bluebook

        offender = bluebook.aggregates.find do |aggregate|
          !tenant_capable?(registry, bound_adapter(registry, domain, aggregate))
        end
        return unless offender

        raise WiringError, ungoverned_wording(domain, offender, bound_adapter(registry, domain, offender))
      end

      def bound_adapter(registry, domain, aggregate)
        Ports::Persistence::BindingPolicy.resolve(registry, domain, aggregate).adapter
      end

      def ungoverned_wording(domain, offender, adapter_name)
        "#{domain}::#{offender.hecks_name} is bound to #{adapter_name}, which is not " \
          "tenant_capable? — booting #{domain} for more than one tenant would share " \
          "#{adapter_name}'s own storage across tenants that must never see each other's data. " \
          "Bind a tenant-capable adapter (Memory, PostgresEra with its own schema: per tenant), " \
          "or keep #{domain} single-tenant."
      end

      # Same defensive shape as EraCheck#lineage_capable? — a class that
      # doesn't respond at all, or whose lookup raises, is false, not an error.
      def tenant_capable?(registry, adapter_name)
        BestEffort.call(false) do
          adapter_class = registry.adapters[adapter_name] && registry.adapter_class(adapter_name)
          adapter_class.respond_to?(:tenant_capable?) && adapter_class.tenant_capable?
        end
      end
    end
  end
end

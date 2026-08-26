require "spec_helper"

RSpec.describe Hecks::Projector::Exporter do
  describe ".lineage" do
    # A REAL PostgresEra binding, not `boot_in_memory`'s own override to
    # Memory — `Exporter.lineage`'s whole job is answering "which
    # adapter is this aggregate actually bound to," so a spec that
    # rebinds Order to Memory first would only ever prove the empty
    # case. `POSTGRES_ERA_ADAPTER` (the DSL declaration, InMemoryDomain's
    # own constant) plus requiring the era plugin (ADR 0033 — `Exporter.
    # lineage` refuses to answer at all unless it's loaded) — the same
    # pairing bin/project_rust's own header explains — is enough:
    # `lineage_capable?`'s `require "pg"` stays lazy, inside `PostgresEra.
    # connect_for` only, so this never needs a live database.
    def registry_with_pizzas_bound_to_postgres
      require InMemoryDomain::ERA_PLUGIN
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)
        Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.hecksagon"))
      end
      registry
    end

    it "names a Postgres-bound aggregate, qualified by name and storage_name" do
      registry = registry_with_pizzas_bound_to_postgres

      expect(described_class.lineage(registry, "Pizzas"))
        .to eq(capable_aggregates: [{ name: "Order", storage_name: "order" }])
    end

    it "answers empty for a domain with nothing bound to a lineage-capable adapter" do
      registry = boot_in_memory.registry

      expect(described_class.lineage(registry, "Pizzas")).to eq(capable_aggregates: [])
    end

    it "agrees with Runtime::EraCheck's own capability predicates, not a re-derived rule" do
      registry = registry_with_pizzas_bound_to_postgres
      order = registry.bluebooks.fetch("Pizzas").aggregate("Order")
      adapter = Hecks::Runtime::EraCheck.adapter_for(registry, "Pizzas", order)

      expect(adapter).to eq("PostgresEra")
      expect(Hecks::Runtime::EraCheck.lineage_capable?(registry, adapter)).to be true
    end
  end
end

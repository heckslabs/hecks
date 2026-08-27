require "spec_helper"
require "hecks/ports/persistence/plugins/era"

RSpec.describe Hecks::Projector::Exporter do
  # H4 (2026-08-10 audit) — a rekey's SQL was absent from `translation_
  # aggregate`, so `ApprovalDigest.edge_digest` (which hashes exactly
  # that shape) could not tell two edges with different `rekey sql:`
  # apart, and a human approval bound to one rekey's digest silently
  # kept covering any other rekey SQL swapped in after approval. Fixed
  # by folding `rekeys` (and `backfills`) into `translation_aggregate`.
  describe ".translation_hash / rekey coverage" do
    def edge_with_rekey(sql)
      aggregate = Hecks::Bluebook::TranslationAggregate.new(
        name:   "Order",
        rekeys: [Hecks::Bluebook::TranslationRekey.new(sql)]
      )
      Hecks::Bluebook::Translation.new(domain: "Pizzas", from: "aaaa", to: "bbbb", aggregates: [aggregate])
    end

    it "changes the digest when the rekey SQL changes" do
      edge_a = edge_with_rekey("SELECT id FROM orders WHERE kind = 'legacy'")
      edge_b = edge_with_rekey("SELECT id FROM orders WHERE kind = 'current'")

      digest_a = Hecks::Translation::Audit.edge_digest(edge_a)
      digest_b = Hecks::Translation::Audit.edge_digest(edge_b)

      expect(digest_a).not_to eq(digest_b)
    end

    it "keeps the digest stable when nothing about the rekey changed" do
      edge_a = edge_with_rekey("SELECT id FROM orders WHERE kind = 'legacy'")
      edge_a_again = edge_with_rekey("SELECT id FROM orders WHERE kind = 'legacy'")

      expect(Hecks::Translation::Audit.edge_digest(edge_a))
        .to eq(Hecks::Translation::Audit.edge_digest(edge_a_again))
    end

    it "invalidates an existing approval when the rekey SQL is edited post-approval" do
      original_sql = "SELECT id FROM orders WHERE kind = 'legacy'"
      approved_digest = Hecks::Translation::Audit.edge_digest(edge_with_rekey(original_sql))

      edited_edge = edge_with_rekey("SELECT id FROM orders WHERE kind = 'tampered'")

      expect(Hecks::Translation::Audit.edge_digest(edited_edge)).not_to eq(approved_digest)
    end

    it "carries the rekey sql into translation_hash's aggregate shape" do
      edge = edge_with_rekey("SELECT id FROM orders")

      rekeys = described_class.translation_hash(edge)[:aggregates].first[:rekeys]

      expect(rekeys).to eq([{ sql: "SELECT id FROM orders" }])
    end
  end

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

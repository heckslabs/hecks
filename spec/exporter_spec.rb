require "spec_helper"
require "hecks/ports/persistence/plugins/era"

RSpec.describe Hecks::Projector::Exporter do
  # Pins that rekey SQL is part of the digested shape: an approval must lapse when
  # the SQL is swapped afterwards.
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

  # A backfill default is what every old row reads, so editing it must lapse the approval too.
  describe ".translation_hash / backfill coverage" do
    def edge_with_backfill(name, default)
      aggregate = Hecks::Bluebook::TranslationAggregate.new(
        name:      "Order",
        backfills: [Hecks::Bluebook::TranslationBackfill.new(name, default)]
      )
      Hecks::Bluebook::Translation.new(domain: "Pizzas", from: "aaaa", to: "bbbb", aggregates: [aggregate])
    end

    it "changes the digest when the backfill default changes" do
      approved = Hecks::Translation::Audit.edge_digest(edge_with_backfill(:email, "a@example.com"))

      expect(Hecks::Translation::Audit.edge_digest(edge_with_backfill(:email, "b@example.com"))).not_to eq(approved)
    end

    it "changes the digest when the backfilled attribute changes" do
      approved = Hecks::Translation::Audit.edge_digest(edge_with_backfill(:email, "a@example.com"))

      expect(Hecks::Translation::Audit.edge_digest(edge_with_backfill(:contact, "a@example.com"))).not_to eq(approved)
    end

    it "keeps the digest stable when nothing about the backfill changed" do
      edge = edge_with_backfill(:email, "a@example.com")
      same_edge_again = edge_with_backfill(:email, "a@example.com")

      expect(Hecks::Translation::Audit.edge_digest(edge)).to eq(Hecks::Translation::Audit.edge_digest(same_edge_again))
    end

    it "carries the backfill into translation_hash's aggregate shape" do
      exported = described_class.translation_hash(edge_with_backfill(:email, "a@example.com"))

      expect(exported[:aggregates].first[:backfills]).to eq([{ name: "email", default: "a@example.com" }])
    end
  end

  # Pizzas' hecksagon attaches Governance, which `provides "authorization"`; the bare
  # bluebook attaches nothing.
  def pizzas_registry(with_hecksagon:)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::PIZZAS_BLUEBOOK)
      Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.hecksagon")) if with_hecksagon
    end
    registry
  end

  describe ".authorization" do
    it "names the attached chapter that provides authorization, with its declared verbs qualified" do
      expect(described_class.authorization(pizzas_registry(with_hecksagon: true), "Pizzas")).to eq(
        provider:             "Governance",
        grant:                "Governance::RoleAssignment.Assign",
        assignments:          "Governance::RoleAssignment.AssignmentsForActor",
        assignment_aggregate: "Governance::RoleAssignment"
      )
    end

    it "answers empty for a domain that attaches no authorization provider" do
      expect(described_class.authorization(pizzas_registry(with_hecksagon: false), "Pizzas")).to eq({})
    end
  end

  describe ".membership" do
    it "answers empty for a domain that attaches no membership provider" do
      expect(described_class.membership(pizzas_registry(with_hecksagon: true), "Pizzas")).to eq({})
    end
  end

  describe ".identity" do
    it "answers empty for a domain that attaches no identity provider" do
      expect(described_class.identity(pizzas_registry(with_hecksagon: true), "Pizzas")).to eq({})
    end

    it "names the attached chapter that provides identity, with its declared verbs qualified" do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/identity.bluebook"))
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/governance.bluebook"))
        Hecks.hecksagon("Probe") do
          uses_framework "Identity"
          uses_framework "Governance"
        end
        Hecks.hecksagon("Identity") do
          uses_framework "Governance"
          Identity::Identity.persisted_by("Memory")
          Identity::ExternalIdentifier.persisted_by("Memory")
        end
        sibling_governance!
      end

      expect(described_class.identity(registry, "Probe")).to eq(
        provider: "Identity",
        register: "Identity::Identity.Register",
        link:     "Identity::ExternalIdentifier.Link",
        resolve:  "Identity::ExternalIdentifier.ResolvedBy"
      )
    end
  end

  describe ".lineage" do
    # Needs a real PostgresEra binding, not `boot_in_memory`'s Memory override, and the
    # era plugin loaded (ADR 0033). `require "pg"` stays lazy, so no database is needed.
    def registry_with_directory_bound_to_postgres
      require InMemoryDomain::ERA_PLUGIN
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/directory/bluebook/directory.bluebook"))
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/directory/bluebook/directory.hecksagon"))
      end
      registry
    end

    it "names a Postgres-bound aggregate, qualified by name and storage_name" do
      registry = registry_with_directory_bound_to_postgres

      expect(described_class.lineage(registry, "Directory"))
        .to eq(capable_aggregates: [{ name: "Member", storage_name: "member" }])
    end

    it "answers empty for a domain with nothing bound to a lineage-capable adapter" do
      registry = boot_in_memory.registry

      expect(described_class.lineage(registry, "Pizzas")).to eq(capable_aggregates: [])
    end

    it "agrees with Runtime::EraCheck's own capability predicates, not a re-derived rule" do
      registry = registry_with_directory_bound_to_postgres
      member = registry.bluebooks.fetch("Directory").aggregate("Member")
      adapter = Hecks::Runtime::EraCheck.adapter_for(registry, "Directory", member)

      expect(adapter).to eq("PostgresEra")
      expect(Hecks::Runtime::EraCheck.lineage_capable?(registry, adapter)).to be true
    end
  end
end

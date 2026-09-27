require "spec_helper"
require "tmpdir"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"
require "pg"

# Whether a cross-aggregate hop query answers correctly on the SQL adapters
# (Sqlite, Postgres, PostgresEra).
#
# It does: `Runtime::ReferenceHop.apply` folds the hop into a local `in:` clause inside
# `QueryInterpreter#call`, so `SqlQueryBuilder#query_expression` never sees an "owner/field" name.
# Postgres and PostgresEra need a real server; under `CI` the shared probe raises instead of
# skipping, and the postgres_io_spec_files list puts this file in a Postgres leg.
# `order_by` on a hop field is refused at DSL-seal time (`seal_query_hop`); dsl_spec.rb covers it.
RSpec.describe "cross-aggregate hop queries answer correctly on real SQL adapters, not just Memory", :io do
  # Named apart from query_hop_spec.rb's HOP_CHAIN: load_hygiene_spec.rb rejects a top-level
  # constant name shared across spec files.
  HOP_CHAIN_AGREEMENT = File.join(InMemoryDomain::ROOT, "spec/fixtures/hop_chain.bluebook")
  HOP_AGREEMENT_DB = "hecks_query_hop_agreement_spec".freeze

  def postgres_available? = PostgresProbe.available?

  before(:all) do
    next unless postgres_available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{HOP_AGREEMENT_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{HOP_AGREEMENT_DB}")
    admin.close
  end

  after(:all) do
    next unless postgres_available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{HOP_AGREEMENT_DB} WITH (FORCE)")
    admin.close
  end

  before do
    next unless postgres_available?

    scrub = PG.connect(dbname: HOP_AGREEMENT_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  # The `Hecks.world` block carries adapter settings; a `persisted_by(...) do` block belongs here.
  def declare_hop_world(adapter, sqlite_root)
    case adapter
    when "Postgres"
      Hecks.world("HopChain") { persisted_by("Postgres") { database HOP_AGREEMENT_DB } }
    when "PostgresEra"
      # `allow_superuser`: PostgresEra refuses to boot as a superuser (its write-fence is row-level
      # security), and the fence is not under test.
      Hecks.world("HopChain") do
        persisted_by("PostgresEra") do
          database HOP_AGREEMENT_DB
          allow_superuser true
        end
      end
    when "Sqlite"
      Hecks.world("HopChain") { persisted_by("SqlitePersistence") { database File.join(sqlite_root, "hop_chain.db") } }
    end
  end

  # `binder` bare-persists; adapter settings live in a separate `Hecks.world` block, as in
  # `IsolatedBoot#rebind_to_postgres!`.
  def boot_hop_chain(adapter:, sqlite_root: nil)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER) # Node stays Memory-bound either way, see below
      Kernel.load(InMemoryDomain::POSTGRES_ADAPTER) if adapter == "Postgres"
      Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER) if adapter == "PostgresEra"
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")) if adapter == "Sqlite"
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(HOP_CHAIN_AGREEMENT)
      # `SqlitePersistence` is the registered port-binding name, not the bare `Sqlite` class.
      bind_name = adapter == "Sqlite" ? "SqlitePersistence" : adapter
      Hecks.hecksagon("HopChain") do
        HopChain::Client.persisted_by(bind_name)
        HopChain::Engagement.persisted_by(bind_name)
        HopChain::Proposal.persisted_by(bind_name)
        # Node stays Memory-bound: its self-referential chain is proven in query_hop_spec.rb.
        HopChain::Node.persisted_by("Memory")
      end
      declare_hop_world(adapter, sqlite_root)
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def seed(runtime)
    runtime.dispatch_flat("HopChain::Client.Register", name: { value: "Acme" })
    runtime.dispatch_flat("HopChain::Client.Register", name: { value: "Zombie Corp" })
    runtime.dispatch_flat("HopChain::Client.Churn", name: { value: "Zombie Corp" })

    runtime.dispatch_flat("HopChain::Engagement.Start", client: "Acme", reference: { value: "e-1" })
    runtime.dispatch_flat("HopChain::Engagement.Demo", reference: { value: "e-1" })
    runtime.dispatch_flat("HopChain::Engagement.Start", client: "Zombie Corp", reference: { value: "e-2" })
    runtime.dispatch_flat("HopChain::Engagement.Demo", reference: { value: "e-2" })

    runtime.dispatch_flat("HopChain::Proposal.Draft", engagement: "e-1", number: { value: "P-1" })
    runtime.dispatch_flat("HopChain::Proposal.Send", number: { value: "P-1" })
    runtime.dispatch_flat("HopChain::Proposal.Draft", engagement: "e-2", number: { value: "P-2" })
    runtime.dispatch_flat("HopChain::Proposal.Send", number: { value: "P-2" })
    runtime.dispatch_flat("HopChain::Proposal.Draft", number: { value: "P-3" })
    runtime.dispatch_flat("HopChain::Proposal.Send", number: { value: "P-3" })
  end

  def ids(runtime, query) = runtime.query(query).map { |r| r[:id] }

  # Hand-computed expectations, as an independent oracle rather than a diff against Memory.
  shared_examples "hop queries answer correctly" do
    it "answers a single hop" do
      expect(ids(runtime, "HopChain::Engagement.WithActiveClient")).to eq(%w[e-1])
    end

    it "answers a two-hop chain" do
      expect(ids(runtime, "HopChain::Proposal.AwaitingReplyFromActiveClients")).to eq(%w[P-1])
    end

    it "combines a hop with a local clause, an order, and a limit" do
      expect(ids(runtime, "HopChain::Proposal.PricedAboveViaEngagement")).to eq(%w[P-1])
    end

    it "never lets a nil reference satisfy a negated hop clause" do
      expect(ids(runtime, "HopChain::Proposal.SentButNotFromActiveClients")).to eq(%w[P-2])
    end
  end

  # A green agreement proves nothing if the bind silently fell back to Memory, so each
  # SQL leg first checks the seeded rows really landed in the engine under test.
  def relation_exists?(name)
    db = PG.connect(dbname: HOP_AGREEMENT_DB)
    db.exec_params("SELECT to_regclass($1) IS NOT NULL AS present", [name])[0]["present"] == "t"
  ensure
    db&.close
  end

  describe "Postgres" do
    before { skip "no reachable local Postgres — set up a local server to run this spec" unless postgres_available? }

    let(:runtime) { boot_hop_chain(adapter: "Postgres") }

    before { seed(runtime) }

    it "stores the referencing aggregate in a real table" do
      expect(relation_exists?("public.proposal")).to be(true)
    end

    it_behaves_like "hop queries answer correctly"
  end

  describe "PostgresEra" do
    before { skip "no reachable local Postgres — set up a local server to run this spec" unless postgres_available? }

    let(:runtime) { boot_hop_chain(adapter: "PostgresEra") }

    before { seed(runtime) }

    it "stores the referencing aggregate in the era journal" do
      expect(relation_exists?("public.hecks_journal_hop_chain")).to be(true)
    end

    it_behaves_like "hop queries answer correctly"
  end

  describe "Sqlite" do
    around do |example|
      Dir.mktmpdir("hecks-hop-agreement") do |dir|
        @sqlite_root = dir
        example.run
      end
    end

    let(:runtime) { boot_hop_chain(adapter: "Sqlite", sqlite_root: @sqlite_root) }

    before { seed(runtime) }

    it "stores the referencing aggregate in a real database file" do
      expect(File.size(File.join(@sqlite_root, "hop_chain.db"))).to be_positive
    end

    it_behaves_like "hop queries answer correctly"
  end
end

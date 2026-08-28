require "spec_helper"
require "tmpdir"
require_relative "../support/postgres_probe"
require "pg"

# WHETHER A CROSS-AGGREGATE HOP QUERY (spec/runtime/query_hop_spec.rb's
# own Memory-only proof) ANSWERS CORRECTLY ON A REAL SQL ADAPTER —
# flagged as a still-open question by docs/prds/02-fuzzer-real-adapters.md
# and docs/1.0-readiness.md after the sibling index-DDL bug
# (schema_builder.rb#index_field!, fixed 2026-08-27) turned out to be a
# real gap for the SAME "owner/field" shape.
#
# Investigated and found NOT a gap, for a structural reason worth pinning
# rather than re-deriving: `Runtime::ReferenceHop.apply` runs inside
# `QueryInterpreter#call`, BEFORE `Ports::Query.execute` ever reaches an
# adapter (lib/hecks/runtime/query_interpreter.rb:34) — a hop where-clause
# is folded into a synthetic LOCAL `in:` clause on the referencing
# attribute for every engine alike, so `SqlQueryBuilder#query_expression`
# never actually sees a "owner/field"-shaped field name. The index bug and
# this non-bug share a root cause description ("owner/field" reaching SQL
# compilation) but are opposite findings — one was real, this one isn't.
#
# `order_by` on a hop field is the other half of "hop-path querying,"
# and it needs no runtime proof at all: it's refused at DSL-seal time
# (aggregate_builder.rb's `seal_query_hop`, `ordering:` branch — "an ask
# is ordered by what its own answering rows hold, and a hop answers with
# a candidate set, not a sort key"), so no bluebook can ever declare one,
# on any adapter. spec/dsl_spec.rb already covers that refusal; not
# duplicated here.
RSpec.describe "cross-aggregate hop queries answer correctly on real SQL adapters, not just Memory",
               io: true do
  # Named distinctly from spec/runtime/query_hop_spec.rb's own top-level
  # HOP_CHAIN (same fixture, different file) — load_hygiene_spec.rb
  # flags any top-level constant name shared across spec files, and two
  # `HOP_CHAIN`s pointing at the identical path is still a collision the
  # guard is right to catch.
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

  # `binder` bare-persists (`persisted_by("Sqlite")`/`persisted_by("Postgres")`,
  # no block) — settings live in a separate `Hecks.world` block, same split
  # `IsolatedBoot#rebind_to_postgres!` uses and for the same reason: a
  # `persisted_by(...) do ... end` block is NOT how this DSL spells adapter
  # settings, `Hecks.world "<Name>" do persisted_by("X") do ... end end` is.
  def boot_hop_chain(adapter:, sqlite_root: nil)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER) # Node stays Memory-bound either way, see below
      Kernel.load(InMemoryDomain::POSTGRES_ADAPTER) if adapter == "Postgres"
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")) if adapter == "Sqlite"
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(HOP_CHAIN_AGREEMENT)
      # `SqlitePersistence` — the real registered port-binding name, not
      # the bare `Sqlite` class (see isolated_boot.rb's own note on the
      # same distinction).
      bind_name = adapter == "Sqlite" ? "SqlitePersistence" : adapter
      Hecks.hecksagon("HopChain") do
        ::HopChain::Client.persisted_by(bind_name)
        ::HopChain::Engagement.persisted_by(bind_name)
        ::HopChain::Proposal.persisted_by(bind_name)
        # Node's own self-referential chain (spec/runtime/query_hop_spec.rb's
        # "revisits the same aggregate type" case) is proven once on Memory
        # already — this file's job is the SQL-adapter question for a
        # cross-AGGREGATE hop, so Node stays Memory-bound rather than
        # tripling every case below for no new coverage.
        ::HopChain::Node.persisted_by("Memory")
      end
      if adapter == "Postgres"
        Hecks.world "HopChain" do
          persisted_by("Postgres") { database HOP_AGREEMENT_DB }
        end
      elsif adapter == "Sqlite"
        Hecks.world "HopChain" do
          persisted_by("SqlitePersistence") { database File.join(sqlite_root, "hop_chain.db") }
        end
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def seed(runtime)
    runtime.dispatch("HopChain::Client.Register", name: { value: "Acme" })
    runtime.dispatch("HopChain::Client.Register", name: { value: "Zombie Corp" })
    runtime.dispatch("HopChain::Client.Churn", name: { value: "Zombie Corp" })

    runtime.dispatch("HopChain::Engagement.Start", client: "Acme", reference: { value: "e-1" })
    runtime.dispatch("HopChain::Engagement.Demo", reference: { value: "e-1" })
    runtime.dispatch("HopChain::Engagement.Start", client: "Zombie Corp", reference: { value: "e-2" })
    runtime.dispatch("HopChain::Engagement.Demo", reference: { value: "e-2" })

    runtime.dispatch("HopChain::Proposal.Draft", engagement: "e-1", number: { value: "P-1" })
    runtime.dispatch("HopChain::Proposal.Send", number: { value: "P-1" })
    runtime.dispatch("HopChain::Proposal.Draft", engagement: "e-2", number: { value: "P-2" })
    runtime.dispatch("HopChain::Proposal.Send", number: { value: "P-2" })
    runtime.dispatch("HopChain::Proposal.Draft", number: { value: "P-3" })
    runtime.dispatch("HopChain::Proposal.Send", number: { value: "P-3" })
  end

  def ids(runtime, query) = runtime.query(query).map { |r| r[:id] }

  # THE SAME HAND-COMPUTED EXPECTATIONS spec/runtime/query_hop_spec.rb
  # already pins for Memory — repeated here as an independent oracle
  # rather than merely diffed against Memory's own answer, same discipline
  # spec/adapters/query_agreement_spec.rb's own header explains: engines
  # sharing one bug would still "agree."
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

  describe "Postgres" do
    before { skip "no reachable local Postgres — set up a local server to run this spec" unless postgres_available? }

    let(:runtime) { boot_hop_chain(adapter: "Postgres") }

    before { seed(runtime) }

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

    it_behaves_like "hop queries answer correctly"
  end
end

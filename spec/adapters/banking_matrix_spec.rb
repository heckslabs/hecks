require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe "Banking across persistence adapters" do
  ADAPTER_MATRIX_BLUEBOOK = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")
  ADAPTERS = {
    "Memory" => InMemoryDomain::MEMORY_ADAPTER,
    "Heki"   => File.join(InMemoryDomain::ROOT, "lib/hecksagain/adapters/driven/heki.adapter"),
    "SqlitePersistence" => File.join(InMemoryDomain::ROOT, "lib/hecksagain/adapters/driven/sqlite.adapter"),
    "SqliteProjection" => File.join(InMemoryDomain::ROOT, "lib/hecksagain/adapters/driven/sqlite.adapter")
  }.freeze
  AUTHORITATIVE_ADAPTERS = %w[Memory Heki SqlitePersistence].freeze

  around do |example|
    @dir = Dir.mktmpdir("hecksagain-banking-adapters-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  def boot(adapter, projected: false, root: @dir)
    registry = Hecksagain::Runtime::Registry.new(root: root)

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecksagain/ports/projection.port"))
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(ADAPTERS.fetch(adapter)) unless adapter == "Memory"
      Kernel.load(ADAPTERS.fetch("SqliteProjection")) if projected
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(ADAPTER_MATRIX_BLUEBOOK)
      Hecks.hecksagon("Banking") do
        Banking::Customer.persisted_by(adapter)
        Banking::Customer.projected_by("SqliteProjection") if projected
        Banking::Account.persisted_by(adapter)
        Banking::Account.projected_by("SqliteProjection") if projected
        Banking::Transfer.persisted_by(adapter)
        Banking::Transfer.projected_by("SqliteProjection") if projected
        Banking::ATMCard.persisted_by(adapter)
        Banking::ATMCard.projected_by("SqliteProjection") if projected
        Banking::CardPayment.persisted_by(adapter)
        Banking::CardPayment.projected_by("SqliteProjection") if projected
        Banking::ExternalTransfer.persisted_by(adapter)
        Banking::ExternalTransfer.projected_by("SqliteProjection") if projected
        Banking::ScheduledPayment.persisted_by(adapter)
        Banking::ScheduledPayment.projected_by("SqliteProjection") if projected
        Banking::SafeDepositBox.persisted_by(adapter)
        Banking::SafeDepositBox.projected_by("SqliteProjection") if projected
      end
      if adapter != "Memory"
        adapter_name = adapter
        root         = root
        Hecks.world("Banking") do
          if adapter_name != "Memory"
            persisted_by(adapter_name) do
              adapter_name == "SqlitePersistence" ? database(File.join(root, "banking.db")) : dir(root)
            end
          end
          projected_by("SqliteProjection") { database(File.join(root, "banking-projection.db")) } if projected
        end
      end
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  def replay_matrix(runtime)
    script = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/banking.json")))
    refusals = []
    queries = []

    script.fetch("steps").each do |step|
      args = step.fetch("args", {}).transform_keys(&:to_sym)
      if (question = step["query"])
        begin
          queries << { query: question, rows: runtime.query(question, **args).map(&:to_h) }
        rescue StandardError => error
          queries << { query: question, error: error.message }
        end
      else
        begin
          runtime.dispatch(step.fetch("verb"), **args)
        rescue StandardError => error
          refusals << { verb: step.fetch("verb"), error: error.message }
        end
      end
    end

    stores = runtime.registry.bluebooks.each_with_object({}) do |(domain, bluebook), all|
      bluebook.aggregates.each do |aggregate|
        all["#{domain}::#{aggregate.name}"] = runtime.registry.repository(domain, aggregate).all.sort_by(&:id).map(&:to_h)
      end
    end

    JSON.parse(JSON.generate(refusals: refusals, queries: queries, stores: stores))
  end

  # A command is a Ruby class and answers `hecks_name`; a query is still an IR
  # object and answers `name`. This walks both kinds, so it asks for whichever the
  # declaration has — and collapses to `hecks_name` when queries cross over too.
  def verb_name(declaration)
    declaration.respond_to?(:hecks_name) ? declaration.hecks_name : declaration.name
  end

  def declared_verbs(runtime, kind)
    bluebook = runtime.registry.bluebook("Banking")
    bluebook.aggregates.flat_map do |aggregate|
      direct = aggregate.public_send(kind).map { |declaration| "Banking::#{aggregate.hecks_name}.#{verb_name(declaration)}" }
      nested = aggregate.entities.flat_map do |entity|
        entity.public_send(kind).map { |declaration| "Banking::#{aggregate.hecks_name}.#{entity.hecks_name}.#{verb_name(declaration)}" }
      end
      direct + nested
    end.sort
  end

  AUTHORITATIVE_ADAPTERS.each do |adapter|
    it "keeps the same account result through #{adapter}" do
      runtime = boot(adapter)
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c" }, name: { given: "Ada", family: "Lovelace" },
                                                   email: { address: "ada@example.com" })
      runtime.dispatch("Banking::Account.Open", customer_id: "c", number: { value: "a" }, kind: { name: "current" }, daily_limit: { cents: 1_000 })
      runtime.dispatch("Banking::Account.Credit", number: { value: "a" }, amount: { cents: 500, currency: "USD" }, narrative: { text: "Opening" })
      runtime.dispatch("Banking::Account.Debit", number: { value: "a" }, amount: { cents: 125, currency: "USD" }, narrative: { text: "Lunch" })

      account = runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account")).find("a")
      expect(account[:balance].to_h).to eq(cents: 375, currency: "USD")
      expect(account[:ledger].map { |entry| entry[:amount].to_h }).to eq([{ cents: 500, currency: "USD" }, { cents: 125, currency: "USD" }])
    end
  end

  it "reads the projection after catch-up and keeps all three stores in parity" do
    runtime = boot("Heki", projected: true)
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c" }, name: { given: "Ada", family: "Lovelace" }, email: { address: "ada@example.com" })
    runtime.dispatch("Banking::Account.Open", customer_id: "c", number: { value: "a" }, kind: { name: "current" }, daily_limit: { cents: 1_000 })

    before = runtime.query("Banking.customer_portfolio", customer: "c")
    workers = runtime.registry.bluebooks.fetch("Banking").aggregates.filter_map do |aggregate|
      Hecksagain::Ports::Projection.worker(runtime.registry, "Banking", aggregate)
    end
    workers.each(&:catch_up!)
    # WHICH REPOSITORY, not which methods. `read_repository` hands back the
    # authoritative store whenever the projection is judged stale, and Heki
    # answers `query_read_model` too — so `respond_to` passed either way and
    # a projection silently declining to serve would have read as success.
    customer = runtime.registry.bluebook("Banking").aggregate("Customer")
    projection_repository = runtime.registry.read_repository("Banking", customer)
    expect(projection_repository.adapter).to be_a(Hecksagain::Adapters::SqliteProjection)
    expect(projection_repository).not_to be(runtime.registry.repository("Banking", customer))
    after = runtime.query("Banking.customer_portfolio", customer: "c")
    expect(after).to eq(before)
    expect(workers.map(&:checkpoint)).to eq(workers.map { |worker| worker.projection.entries.length })

    # Refresh is safe to repeat after a restart: it rebuilds from the durable
    # authoritative journal without changing the report.
    workers.each(&:catch_up!)
    expect(runtime.query("Banking.customer_portfolio", customer: "c")).to eq(after)

    workers.each do |worker|
      aggregate = worker.projection.aggregate
      expect(worker.projection.all.map(&:to_h)).to eq(runtime.registry.repository("Banking", aggregate).all.map(&:to_h))
    end
  end

  it "runs every banking command and query through every persistence topology" do
    coverage = boot("Memory", root: File.join(@dir, "coverage"))
    script = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/banking.json")))
    commands = script.fetch("steps").filter_map { |step| step["verb"] }.uniq.sort
    queries = script.fetch("steps").filter_map { |step| step["query"] }.uniq.sort
    expect(commands).to include(*declared_verbs(coverage, :commands))
    expect(queries).to include(*declared_verbs(coverage, :queries))

    topologies = %w[Memory Heki SqlitePersistence]
    results = topologies.to_h do |adapter|
      root = File.join(@dir, adapter.downcase)
      [adapter, replay_matrix(boot(adapter, root: root))]
    end

    baseline = results.fetch("Memory")
    results.each { |topology, result| expect(result).to eq(baseline), topology }
  end

  it "keeps the customer portfolio read model in parity between memory and sqlite" do
    memory = boot("Memory", root: File.join(@dir, "read-model-memory"))
    sqlite = boot("SqlitePersistence", root: File.join(@dir, "read-model-sqlite"))

    # Exercise the complete banking matrix before comparing the domain-level
    # report. This ensures the read model sees the same successful commands,
    # refusals, and aggregate heads as the corpus replay.
    replay_matrix(memory)
    replay_matrix(sqlite)

    args = { customer: "CUST-0001" }
    # SQLite returns JSON-decoded reference payloads with string keys while
    # Memory retains symbol keys. Compare the wire representation so this
    # checks report data parity rather than Ruby hash-key spelling.
    canonical = ->(rows) { JSON.parse(JSON.generate(rows)) }
    expect(canonical.call(sqlite.query("Banking.customer_portfolio", **args)))
      .to eq(canonical.call(memory.query("Banking.customer_portfolio", **args)))
  end
end

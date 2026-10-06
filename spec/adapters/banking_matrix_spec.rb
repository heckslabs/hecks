require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe "Banking across persistence adapters" do
  ADAPTER_MATRIX_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR
  ADAPTERS = {
    "Memory"            => InMemoryDomain::MEMORY_ADAPTER,
    "Heki"              => File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/heki.adapter"),
    "SqlitePersistence" => File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter"),
    "SqliteProjection"  => File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")
  }.freeze
  AUTHORITATIVE_ADAPTERS = %w[Memory Heki SqlitePersistence].freeze
  BANKING_AGGREGATES = %w[Customer Account Transfer ATMCard CardPayment ExternalTransfer ScheduledPayment
                          SafeDepositBox OnboardingCase Statement].freeze

  around do |example|
    @dir = Dir.mktmpdir("hecks-banking-adapters-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  def load_banking_ports(adapter, projected)
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/ports/projection.port"))
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(ADAPTERS.fetch(adapter)) unless adapter == "Memory"
    Kernel.load(ADAPTERS.fetch("SqliteProjection")) if projected
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    load_bluebook_files(ADAPTER_MATRIX_BLUEBOOK)
  end

  # Every aggregate persists through `adapter_name`, and is projected when `projected`.
  def declare_banking_hecksagon(adapter_name, projected)
    Hecks.hecksagon("Banking") do
      attaches "Governance"
      BANKING_AGGREGATES.each do |name|
        aggregate = Object.const_get("Banking::#{name}")
        aggregate.persisted_by(adapter_name)
        aggregate.projected_by("SqliteProjection") if projected
      end
    end
  end

  def declare_governance_hecksagon
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def declare_banking_world(adapter_name, projected, root)
    Hecks.world("Banking") do
      persisted_by(adapter_name) do
        adapter_name == "SqlitePersistence" ? database(File.join(root, "banking.db")) : dir(root)
      end
      projected_by("SqliteProjection") { database(File.join(root, "banking-projection.db")) } if projected
    end
  end

  # One fixture boot: each aggregate's persisted_by/projected_by pairing depends on the same
  # `projected` flag.
  def boot(adapter, projected: false, root: @dir)
    registry = Hecks::Runtime::Registry.new(root: root)

    Hecks.with_registry(registry) do
      load_banking_ports(adapter, projected)
      declare_banking_hecksagon(adapter, projected)
      declare_governance_hecksagon
      declare_banking_world(adapter, projected, root) unless adapter == "Memory"
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def banking_script = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/banking.json")))

  def query_result(runtime, question, args)
    { query: question, rows: runtime.query(question, **args).map(&:to_h) }
  rescue StandardError => e
    { query: question, error: e.message }
  end

  # Answers nil when the command went through, and the refusal when it did not.
  def command_refusal(runtime, verb, args)
    runtime.dispatch_flat(verb, **args)
    nil
  rescue StandardError => e
    { verb: verb, error: e.message }
  end

  def replay_step(runtime, step, refusals, queries)
    args = step.fetch("args", {}).transform_keys(&:to_sym)
    if step["query"]
      queries << query_result(runtime, step["query"], args)
    else
      refusal = command_refusal(runtime, step.fetch("verb"), args)
      refusals << refusal if refusal
    end
  end

  def snapshot_stores(runtime)
    runtime.registry.bluebooks.each_with_object({}) do |(domain, bluebook), all|
      bluebook.aggregates.each do |aggregate|
        all["#{domain}::#{aggregate.name}"] = runtime.registry.repository(domain, aggregate).all.sort_by(&:id).map(&:to_h)
      end
    end
  end

  def replay_matrix(runtime)
    refusals = []
    queries = []
    banking_script.fetch("steps").each { |step| replay_step(runtime, step, refusals, queries) }

    JSON.parse(JSON.generate(refusals: refusals, queries: queries, stores: snapshot_stores(runtime)))
  end

  # Commands answer `hecks_name`; queries are still IR objects that answer `name`.
  def verb_name(declaration)
    declaration.respond_to?(:hecks_name) ? declaration.hecks_name : declaration.name
  end

  def aggregate_verbs(aggregate, kind)
    prefix = "Banking::#{aggregate.hecks_name}"
    direct = aggregate.public_send(kind).map { |declaration| "#{prefix}.#{verb_name(declaration)}" }
    nested = aggregate.entities.flat_map do |entity|
      entity.public_send(kind).map { |declaration| "#{prefix}.#{entity.hecks_name}.#{verb_name(declaration)}" }
    end
    direct + nested
  end

  def declared_verbs(runtime, kind)
    runtime.registry.bluebook("Banking").aggregates.flat_map { |aggregate| aggregate_verbs(aggregate, kind) }.sort
  end

  def register_ada(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" }, name: { given: "Ada", family: "Lovelace" },
                                                        email: { address: "ada@example.com" })
  end

  def open_account_a(runtime)
    runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a" }, kind: { name: "current" },
                                                   daily_limit: { cents: 1_000 })
  end

  def move_money(runtime, verb, cents, text)
    runtime.dispatch_flat("Banking::Account.#{verb}", number: { value: "a" }, amount: { cents: cents, currency: "USD" },
                                                      narrative: { text: text })
  end

  def account_a(runtime)
    aggregate = runtime.registry.bluebook("Banking").aggregate("Account")
    runtime.registry.repository("Banking", aggregate).find("a")
  end

  AUTHORITATIVE_ADAPTERS.each do |adapter|
    context "with #{adapter}" do
      before do
        @runtime = boot(adapter)
        register_ada(@runtime)
        open_account_a(@runtime)
        move_money(@runtime, "Credit", 500, "Opening")
        move_money(@runtime, "Debit", 125, "Lunch")
      end

      it "keeps the same account balance through #{adapter}" do
        expect(account_a(@runtime)[:balance].to_h).to eq(cents: 375, currency: "USD")
      end

      it "keeps the same ledger through #{adapter}" do
        ledger = account_a(@runtime)[:ledger].map { |entry| entry[:amount].to_h }

        expect(ledger).to eq([{ cents: 500, currency: "USD" }, { cents: 125, currency: "USD" }])
      end
    end
  end

  context "with Heki projected and caught up" do
    def projection_workers
      @runtime.registry.bluebooks.fetch("Banking").aggregates.filter_map do |aggregate|
        Hecks::Ports::Projection.worker(@runtime.registry, "Banking", aggregate)
      end
    end

    def customer_portfolio = @runtime.query("Banking.customer_portfolio", customer: "c")

    before do
      @runtime = boot("Heki", projected: true)
      register_ada(@runtime)
      open_account_a(@runtime)
      @before = customer_portfolio
      @workers = projection_workers
      @workers.each(&:catch_up!)
    end

    # Assert which repository, not which methods: `read_repository` falls back to the
    # authoritative store when the projection is stale, and Heki also answers
    # `query_read_model`, so a `respond_to` check would pass either way.
    it "reads the projection repository, not the authoritative one", :aggregate_failures do
      customer = @runtime.registry.bluebook("Banking").aggregate("Customer")
      projection_repository = @runtime.registry.read_repository("Banking", customer)

      expect(projection_repository.adapter).to be_a(Hecks::Adapters::SqliteProjection)
      expect(projection_repository).not_to be(@runtime.registry.repository("Banking", customer))
    end

    it "answers the same portfolio after catch-up" do
      expect(customer_portfolio).to eq(@before)
    end

    it "checkpoints every worker at the end of its projection" do
      expect(@workers.map(&:checkpoint)).to eq(@workers.map { |worker| worker.projection.entries.length })
    end

    # Repeating the refresh after a restart rebuilds from the journal without changing the report.
    it "rebuilds the same report when the refresh repeats" do
      @workers.each(&:catch_up!)

      expect(customer_portfolio).to eq(@before)
    end

    it "keeps all three stores in parity" do
      @workers.each do |worker|
        authoritative = @runtime.registry.repository("Banking", worker.projection.aggregate)

        expect(worker.projection.all.map(&:to_h)).to eq(authoritative.all.map(&:to_h))
      end
    end
  end

  context "with every banking command and query" do
    def corpus_steps(key) = banking_script.fetch("steps").filter_map { |step| step[key] }.uniq.sort

    def coverage_runtime = boot("Memory", root: File.join(@dir, "coverage"))

    def results_by_topology
      %w[Memory Heki SqlitePersistence].to_h do |adapter|
        [adapter, replay_matrix(boot(adapter, root: File.join(@dir, adapter.downcase)))]
      end
    end

    it "runs every banking command through the corpus" do
      expect(corpus_steps("verb")).to include(*declared_verbs(coverage_runtime, :commands))
    end

    it "runs every banking query through the corpus" do
      expect(corpus_steps("query")).to include(*declared_verbs(coverage_runtime, :queries))
    end

    it "gives every persistence topology the same results as Memory" do
      results = results_by_topology
      baseline = results.fetch("Memory")

      results.each { |topology, result| expect(result).to eq(baseline), topology }
    end
  end

  # SQLite returns string-keyed reference payloads, Memory symbol-keyed; compare the wire
  # form so only report data is checked.
  def portfolio_on_the_wire(runtime)
    JSON.parse(JSON.generate(runtime.query("Banking.customer_portfolio", customer: "CUST-0001")))
  end

  it "keeps the customer portfolio read model in parity between memory and sqlite" do
    memory = boot("Memory", root: File.join(@dir, "read-model-memory"))
    sqlite = boot("SqlitePersistence", root: File.join(@dir, "read-model-sqlite"))

    # Replay the full matrix first so the read model has seen the same commands, refusals
    # and aggregate heads as the corpus replay.
    [memory, sqlite].each { |runtime| replay_matrix(runtime) }

    expect(portfolio_on_the_wire(sqlite)).to eq(portfolio_on_the_wire(memory))
  end
end

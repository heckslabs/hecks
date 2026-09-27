require "json"
require "open3"
require "securerandom"
require "hecks/ports/persistence/plugins/era"
require_relative "support/postgres_probe"

# Differential test of rust/host's generic lineage read/write path against eras Ruby minted,
# run through a compiled lineage_harness as the RLS-fenced app role (ADR 0029).
RSpec.describe "Rust/Ruby lineage parity (rust/host)", :io do
  RUST_HOST_DIR = File.join(InMemoryDomain::ROOT, "rust", "host")
  SEED_SCRIPT = File.join(RUST_HOST_DIR, "tests", "fixtures", "mint_and_seed_lineage.rb")
  COMPUTE_SEED_SCRIPT = File.join(RUST_HOST_DIR, "tests", "fixtures", "mint_and_seed_lineage_compute.rb")
  MINT_VIA_RUST_SCRIPT = File.join(RUST_HOST_DIR, "tests", "fixtures", "mint_via_rust_matches_ruby.rb")

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?
  end

  # Built once per suite run and memoized, failures included. A failed build raises with cargo's
  # stderr, never skips: these binaries have no feature that could be missing.
  def self.lineage_harness_binary = host_binary("lineage_harness")

  def self.mint_harness_binary = host_binary("mint_harness")

  def self.host_binary(name)
    @host_binaries ||= {}
    result = (@host_binaries[name] ||= build_host_binary(name))
    raise result if result.is_a?(Exception)

    result
  end

  def self.build_host_binary(name)
    _stdout, stderr, status = Open3.capture3("cargo", "build", "--bin", name, chdir: RUST_HOST_DIR)
    unless status.success?
      return RuntimeError.new("`cargo build --bin #{name}` failed in #{RUST_HOST_DIR} " \
                              "(exit #{status.exitstatus}):\n#{stderr}")
    end

    binary = File.join(RUST_HOST_DIR, "target", "debug", name)
    return binary if File.executable?(binary)

    RuntimeError.new("`cargo build --bin #{name}` succeeded but left no executable at #{binary}:\n#{stderr}")
  rescue SystemCallError => e
    RuntimeError.new("`cargo build --bin #{name}` could not run in #{RUST_HOST_DIR}: #{e.message}")
  end

  def drop_scratch!(db_name, owner_role, app_role)
    require "pg"
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{db_name} WITH (FORCE)")
    admin.exec("DROP ROLE IF EXISTS #{owner_role}")
    admin.exec("DROP ROLE IF EXISTS #{app_role}")
    admin.close
  end

  # capture3 so a crashing script's stderr reaches the failure message.
  def seed(db_name, owner_role, app_role, script: SEED_SCRIPT)
    stdout, stderr, status = Open3.capture3("ruby", script, db_name, owner_role, app_role)
    raise "#{File.basename(script)} failed:\nstdout:\n#{stdout}\nstderr:\n#{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def run_harness(binary, db_name, app_role, domain, era, operations)
    stdin = JSON.generate({ "operations" => operations })
    stdout, stderr, status = Open3.capture3(binary, db_name, app_role, domain, era.to_s, stdin_data: stdin)
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\nstdout:\n#{stdout}\nstderr:\n#{stderr}"

    JSON.parse(stdout).fetch("results")
  end

  it "reads every row lineage_harness reports, connecting as the RLS-fenced app role, matching Ruby's own " \
     "translated ground truth exactly" do
    binary = self.class.lineage_harness_binary

    suffix = SecureRandom.hex(4)
    db_name = "rust_host_lineage_#{suffix}"
    owner_role = "rhl_owner_#{suffix}"
    app_role = "rhl_app_#{suffix}"

    ground_truth = seed(db_name, owner_role, app_role)
    storage_name = ground_truth.fetch("storage_name")
    domain = ground_truth.fetch("domain")
    era = ground_truth.fetch("era")

    results = run_harness(binary, db_name, app_role, domain, era, [{ "op" => "read_all", "storage_name" => storage_name }])
    read_all = results.first
    expect(read_all["ok"]).to be(true), read_all["error"]

    rust_rows = read_all.fetch("rows").sort_by { |id, _| id }
    ruby_rows = ground_truth.fetch("rows").sort_by { |id, _| id }
    expect(rust_rows).to eq(ruby_rows)

    # read_by_id for every row; read_all does not exercise it.
    by_id_ops = ruby_rows.map { |id, _| { "op" => "read_by_id", "storage_name" => storage_name, "id" => id } }
    by_id_results = run_harness(binary, db_name, app_role, domain, era, by_id_ops)
    by_id_results.each_with_index do |result, index|
      id, expected_state = ruby_rows[index]
      expect(result["ok"]).to be(true), "read_by_id(#{id.inspect}): #{result['error']}"
      expect(result["state"]).to eq(expected_state)
    end
  ensure
    drop_scratch!(db_name, owner_role, app_role) if db_name
  end

  it "writes a row through lineage_harness's own generic append_lineage_mutation, and Ruby reads it back exactly as written" do
    binary = self.class.lineage_harness_binary

    suffix = SecureRandom.hex(4)
    db_name = "rust_host_lineage_write_#{suffix}"
    owner_role = "rhl_owner_#{suffix}"
    app_role = "rhl_app_#{suffix}"

    ground_truth = seed(db_name, owner_role, app_role)
    domain = ground_truth.fetch("domain")
    era = ground_truth.fetch("era")

    write_op = {
      "op" => "write", "aggregate" => "#{domain}::Account", "id" => "written-by-rust",
      "state" => { "amount" => { "cents" => 999 }, "kind" => { "label" => "written-by-rust" } }
    }
    results = run_harness(binary, db_name, app_role, domain, era, [write_op])
    expect(results.first["ok"]).to be(true), results.first["error"]

    # Reads back as the owner: proves the write is durable for Ruby, not just for Rust.
    require "pg"
    # View name is domain-qualified (docs/decisions/0059); the seed script's domain is Ledger.
    raw = PG.connect("postgres://#{owner_role}@localhost/#{db_name}")
            .exec_params("SELECT state FROM ledger_account_head WHERE id = $1", ["written-by-rust"])
    expect(raw.ntuples).to eq(1)
    expect(JSON.parse(raw[0]["state"])).to eq(write_op["state"])
  ensure
    drop_scratch!(db_name, owner_role, app_role) if db_name
  end

  # Pizzas::Order is a real lineage-capable aggregate with a nested value object, a list and a
  # lifecycle field; one era only, so this checks the generic read against what Ruby wrote.
  # rubocop:disable-next RSpec/ExampleLength
  it "reads a real corpus aggregate (Pizzas::Order) back exactly as Ruby wrote it, through the RLS-fenced app role" do
    binary = self.class.lineage_harness_binary

    suffix = SecureRandom.hex(4)
    db_name = "rust_host_lineage_pizzas_#{suffix}"
    owner_role = "rhl_owner_#{suffix}"
    app_role = "rhl_app_#{suffix}"

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{db_name} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{db_name}")
    admin.exec("DROP ROLE IF EXISTS #{owner_role}")
    admin.exec("CREATE ROLE #{owner_role} LOGIN")
    admin.exec("DROP ROLE IF EXISTS #{app_role}")
    admin.exec("CREATE ROLE #{app_role} LOGIN")
    admin.close
    grant = PG.connect(dbname: db_name)
    grant.exec("GRANT CONNECT ON DATABASE #{db_name} TO #{owner_role}")
    grant.exec("GRANT CONNECT ON DATABASE #{db_name} TO #{app_role}")
    grant.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{owner_role}")
    grant.exec("GRANT USAGE ON SCHEMA public TO #{app_role}")
    grant.close
    owner_url = "postgres://#{owner_role}@localhost/#{db_name}"

    # boot_in_memory supplies only the aggregate's declared shape; check! establishes lineage
    # capability and grants the app role.
    dispatcher = boot_in_memory
    registry = dispatcher.registry
    bluebook = registry.bluebook("Pizzas")
    aggregate = bluebook.aggregate("Order")

    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: File.read(InMemoryDomain::PIZZAS_BLUEBOOK),
      settings: { database: owner_url, role: app_role }
    )

    adapter = Hecks::Adapters::PostgresEra.new(
      aggregate: aggregate, settings: { database: owner_url, domain: "Pizzas", era: 1 }
    )
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: "p1")
    fields = {
      name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } },
      toppings: [{ name: "Basil", amount: 3 }], customer_name: { value: "Alice" }
    }
    fields.each { |name, value| built[name] = Hecks::Runtime::Value.for(aggregate, name, value) }
    adapter.save(built)

    results = run_harness(binary, db_name, app_role, "Pizzas", 1,
                          [{ "op" => "read_by_id", "storage_name" => "order", "id" => "p1" }])
    expect(results.first["ok"]).to be(true), results.first["error"]

    # Compared against the raw view row: Instance#[] answers typed Values, not plain JSON.
    # View name is domain-qualified (docs/decisions/0059).
    raw = PG.connect(owner_url).exec_params("SELECT state FROM pizzas_order_head WHERE id = $1", ["p1"])
    expect(raw.ntuples).to eq(1)
    expect(results.first["state"]).to eq(JSON.parse(raw[0]["state"]))
  ensure
    drop_scratch!(db_name, owner_role, app_role) if db_name
  end

  # compute/rekey has no in-process Ruby reference, so ground truth is Postgres's own compiled SQL.
  it "reads a compute-migrated era back exactly as Postgres's own compiled SQL produced it, minted only " \
     "because a real, matching approval was recorded first" do
    binary = self.class.lineage_harness_binary

    suffix = SecureRandom.hex(4)
    db_name = "rust_host_lineage_compute_#{suffix}"
    owner_role = "rhlc_owner_#{suffix}"
    app_role = "rhlc_app_#{suffix}"

    ground_truth = seed(db_name, owner_role, app_role, script: COMPUTE_SEED_SCRIPT)
    storage_name = ground_truth.fetch("storage_name")
    domain = ground_truth.fetch("domain")
    era = ground_truth.fetch("era")

    results = run_harness(binary, db_name, app_role, domain, era, [{ "op" => "read_all", "storage_name" => storage_name }])
    read_all = results.first
    expect(read_all["ok"]).to be(true), read_all["error"]

    rust_rows = read_all.fetch("rows").sort_by { |id, _| id }
    ruby_rows = ground_truth.fetch("rows").sort_by { |id, _| id }
    expect(rust_rows).to eq(ruby_rows)
    # Every row is in the post-compute shape, including those translated by the mint.
    expect(rust_rows.map { |_, state| state.keys }).to all(contain_exactly("kind", "doubled"))
  ensure
    drop_scratch!(db_name, owner_role, app_role) if db_name
  end

  # Mints the same edge independently in Ruby and in Rust (mint_harness), then diffs the views.
  it "mints the same edge independently in Ruby and in Rust and produces byte-identical account_head views" do
    mint_binary = self.class.mint_harness_binary
    read_binary = self.class.lineage_harness_binary

    stdout, stderr, status = Open3.capture3("ruby", MINT_VIA_RUST_SCRIPT, mint_binary, read_binary)
    raise "#{File.basename(MINT_VIA_RUST_SCRIPT)} failed:\nstdout:\n#{stdout}\nstderr:\n#{stderr}" unless status.success?

    result = JSON.parse(stdout)
    begin
      expect(result.fetch("rust_rows")).to eq(result.fetch("ruby_rows"))
    ensure
      require "pg"
      admin = PG.connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS #{result.fetch('ruby_db')} WITH (FORCE)")
      admin.exec("DROP DATABASE IF EXISTS #{result.fetch('rust_db')} WITH (FORCE)")
      admin.exec("DROP ROLE IF EXISTS #{result.fetch('owner')}")
      admin.close
    end
  end
end

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

  # The throwaway database and the two roles an example works against.
  LineageScratch = Struct.new(:db_name, :owner_role, :app_role)

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?
  end

  after { drop_scratch!(@scratch) if @scratch }

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

  # A role the example later connects as needs the environment's password when the server asks
  # for one (libpq, the Ruby era and the Rust harnesses all read `PGPASSWORD`).
  def login_clause(connection)
    password = ENV.fetch("PGPASSWORD", "")
    password.empty? ? "LOGIN" : "LOGIN PASSWORD #{connection.escape_literal(password)}"
  end

  def new_scratch(label, role_prefix = "rhl")
    suffix = SecureRandom.hex(4)
    LineageScratch.new("rust_host_lineage_#{label}#{suffix}", "#{role_prefix}_owner_#{suffix}", "#{role_prefix}_app_#{suffix}")
  end

  def drop_scratch!(scratch)
    require "pg"
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{scratch.db_name} WITH (FORCE)")
    admin.exec("DROP ROLE IF EXISTS #{scratch.owner_role}")
    admin.exec("DROP ROLE IF EXISTS #{scratch.app_role}")
    admin.close
  end

  # capture3 so a crashing script's stderr reaches the failure message.
  def seed(scratch, script: SEED_SCRIPT)
    stdout, stderr, status = Open3.capture3("ruby", script, scratch.db_name, scratch.owner_role, scratch.app_role)
    raise "#{File.basename(script)} failed:\nstdout:\n#{stdout}\nstderr:\n#{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  # Seeds a scratch database with Ruby-minted eras and returns Ruby's ground truth.
  def seeded(label, role_prefix: "rhl", script: SEED_SCRIPT)
    @scratch = new_scratch(label, role_prefix)
    seed(@scratch, script: script)
  end

  def run_harness(binary, scratch, domain, era, operations)
    stdin = JSON.generate({ "operations" => operations })
    stdout, stderr, status = Open3.capture3(binary, scratch.db_name, scratch.app_role, domain, era.to_s, stdin_data: stdin)
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\nstdout:\n#{stdout}\nstderr:\n#{stderr}"

    JSON.parse(stdout).fetch("results")
  end

  def run_ground_truth(ground_truth, operations)
    run_harness(self.class.lineage_harness_binary, @scratch, ground_truth.fetch("domain"), ground_truth.fetch("era"), operations)
  end

  def sorted_rows(ground_truth) = ground_truth.fetch("rows").sort_by { |id, _| id }

  # What lineage_harness's read_all reports for the seeded storage, after checking it succeeded.
  def harness_rows(ground_truth)
    operations = [{ "op" => "read_all", "storage_name" => ground_truth.fetch("storage_name") }]
    result = run_ground_truth(ground_truth, operations).first
    expect(result["ok"]).to be(true), result["error"]
    result.fetch("rows").sort_by { |id, _| id }
  end

  # read_by_id for every row; read_all does not exercise it.
  def by_id_operations(ground_truth)
    storage_name = ground_truth.fetch("storage_name")
    sorted_rows(ground_truth).map { |id, _| { "op" => "read_by_id", "storage_name" => storage_name, "id" => id } }
  end

  def expect_by_id_reads(ground_truth)
    rows = sorted_rows(ground_truth)
    run_ground_truth(ground_truth, by_id_operations(ground_truth)).each_with_index do |result, index|
      id, expected_state = rows[index]
      expect(result["ok"]).to be(true), "read_by_id(#{id.inspect}): #{result["error"]}"
      expect(result["state"]).to eq(expected_state)
    end
  end

  def owner_url = "postgres://#{@scratch.owner_role}@localhost/#{@scratch.db_name}"

  def write_operation(domain)
    { "op" => "write", "aggregate" => "#{domain}::Account", "id" => "written-by-rust",
      "state" => { "amount" => { "cents" => 999 }, "kind" => { "label" => "written-by-rust" } } }
  end

  # Has lineage_harness append `write_operation`'s row, checking it reported success; returns it.
  def expect_write_via_harness(ground_truth)
    write_op = write_operation(ground_truth.fetch("domain"))
    result = run_ground_truth(ground_truth, [write_op]).first
    expect(result["ok"]).to be(true), result["error"]
    write_op
  end

  def create_database_and_roles(scratch)
    require "pg"
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{scratch.db_name} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{scratch.db_name}")
    [scratch.owner_role, scratch.app_role].each do |role|
      admin.exec("DROP ROLE IF EXISTS #{role}")
      admin.exec("CREATE ROLE #{role} #{login_clause(admin)}")
    end
    admin.close
  end

  def grant_scratch_access(scratch)
    grant = PG.connect(dbname: scratch.db_name)
    [scratch.owner_role, scratch.app_role].each { |role| grant.exec("GRANT CONNECT ON DATABASE #{scratch.db_name} TO #{role}") }
    grant.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{scratch.owner_role}")
    grant.exec("GRANT USAGE ON SCHEMA public TO #{scratch.app_role}")
    grant.close
  end

  # boot_in_memory supplies only the aggregate's declared shape; check! establishes lineage
  # capability and grants the app role.
  def lineage_checked_order
    registry = boot_in_memory.registry
    bluebook = registry.bluebook("Pizzas")
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: File.read(InMemoryDomain::PIZZAS_BLUEBOOK),
      settings: { database: owner_url, role: @scratch.app_role }
    )
    bluebook.aggregate("Order")
  end

  def margherita_fields
    { name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } },
      toppings: [{ name: "Basil", amount: 3 }], customer_name: { value: "Alice" } }
  end

  def save_margherita(aggregate)
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: owner_url, domain: "Pizzas", era: 1 })
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: "p1")
    margherita_fields.each { |name, value| built[name] = Hecks::Runtime::Value.for(aggregate, name, value) }
    adapter.save(built)
  end

  # A scratch database holding one Margherita saved through PostgresEra under a lineage-checked
  # Order.
  def provisioned_margherita
    @scratch = new_scratch("pizzas_")
    create_database_and_roles(@scratch)
    grant_scratch_access(@scratch)
    save_margherita(lineage_checked_order)
  end

  def read_margherita_via_harness
    operation = { "op" => "read_by_id", "storage_name" => "order", "id" => "p1" }
    results = run_harness(self.class.lineage_harness_binary, @scratch, "Pizzas", 1, [operation])
    expect(results.first["ok"]).to be(true), results.first["error"]
    results.first
  end

  def run_mint_via_rust
    stdout, stderr, status = Open3.capture3("ruby", MINT_VIA_RUST_SCRIPT, self.class.mint_harness_binary,
                                            self.class.lineage_harness_binary)
    raise "#{File.basename(MINT_VIA_RUST_SCRIPT)} failed:\nstdout:\n#{stdout}\nstderr:\n#{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def with_minted_databases
    result = run_mint_via_rust
    yield result
  ensure
    drop_minted_databases(result) if result
  end

  def drop_minted_databases(result)
    require "pg"
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{result.fetch("ruby_db")} WITH (FORCE)")
    admin.exec("DROP DATABASE IF EXISTS #{result.fetch("rust_db")} WITH (FORCE)")
    admin.exec("DROP ROLE IF EXISTS #{result.fetch("owner")}")
    admin.close
  end

  it "reads every row lineage_harness reports, connecting as the RLS-fenced app role, matching Ruby's own " \
     "translated ground truth exactly" do
    ground_truth = seeded("")

    expect(harness_rows(ground_truth)).to eq(sorted_rows(ground_truth))
  end

  it "reads each row of a seeded era back by id, matching Ruby's own translated ground truth" do
    expect_by_id_reads(seeded(""))
  end

  it "writes a row through lineage_harness's own generic append_lineage_mutation, and Ruby reads it back exactly as written",
     :aggregate_failures do
    write_op = expect_write_via_harness(seeded("write_"))
    # Reads back as the owner: proves the write is durable for Ruby, not just for Rust.
    # View name is domain-qualified (docs/decisions/0059); the seed script's domain is Ledger.
    raw = PG.connect(owner_url).exec_params("SELECT state FROM ledger_account_head WHERE id = $1", ["written-by-rust"])

    expect(raw.ntuples).to eq(1)
    expect(JSON.parse(raw[0]["state"])).to eq(write_op["state"])
  end

  # Pizzas::Order is a real lineage-capable aggregate with a nested value object, a list and a
  # lifecycle field; one era only, so this checks the generic read against what Ruby wrote.
  it "reads a real corpus aggregate (Pizzas::Order) back exactly as Ruby wrote it, through the RLS-fenced app role",
     :aggregate_failures do
    provisioned_margherita
    result = read_margherita_via_harness
    # Compared against the raw view row: Instance#[] answers typed Values, not plain JSON.
    # View name is domain-qualified (docs/decisions/0059).
    raw = PG.connect(owner_url).exec_params("SELECT state FROM pizzas_order_head WHERE id = $1", ["p1"])

    expect(raw.ntuples).to eq(1)
    expect(result["state"]).to eq(JSON.parse(raw[0]["state"]))
  end

  # compute/rekey has no in-process Ruby reference, so ground truth is Postgres's own compiled SQL.
  it "reads a compute-migrated era back exactly as Postgres's own compiled SQL produced it, minted only " \
     "because a real, matching approval was recorded first", :aggregate_failures do
    ground_truth = seeded("compute_", role_prefix: "rhlc", script: COMPUTE_SEED_SCRIPT)
    rust_rows = harness_rows(ground_truth)

    expect(rust_rows).to eq(sorted_rows(ground_truth))
    # Every row is in the post-compute shape, including those translated by the mint.
    expect(rust_rows.map { |_, state| state.keys }).to all(contain_exactly("kind", "doubled"))
  end

  # Mints the same edge independently in Ruby and in Rust (mint_harness), then diffs the views.
  it "mints the same edge independently in Ruby and in Rust and produces byte-identical account_head views" do
    with_minted_databases do |result|
      expect(result.fetch("rust_rows")).to eq(result.fetch("ruby_rows"))
    end
  end
end

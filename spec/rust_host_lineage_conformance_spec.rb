require "json"
require "open3"
require "securerandom"
require_relative "support/postgres_probe"

# THE LINEAGE DIFFERENTIAL HARNESS — ADR 0029's step 4/5, `rust/host`'s
# own sibling to spec/rust_conformance_spec.rb. That spec proves parity
# for the KERNEL crate (compiled dispatch/type-checking, one process,
# no Postgres); this one proves it for the one thing `rust/host` alone
# does — read and write across a REAL era boundary a REAL Ruby mint
# produced, for the generic lineage path (`journal::
# read_lineage_head_all/_by_id`/`append_lineage_mutation`) every
# lineage-capable aggregate shares, not just `Member`.
#
# `mint_and_seed_lineage.rb` (rust/host/tests/fixtures/) does the
# minting AND the writing, then hands back its own ground truth: era 1's
# raw writes run through Ruby's OWN `Ports::Persistence::Lineage#
# translate` — the same in-process reference the real Layer 2 audit
# checks Postgres's compiled SQL against — merged with era 2's own
# untranslated writes. `lineage_harness` (rust/host/src/bin/) is the
# Rust side: a real compiled binary, connecting as the RLS-fenced app
# role (not the owner — the owner bypasses RLS entirely, which would
# prove nothing about the fence a real deployment actually runs behind),
# reading and writing through nothing but the generic functions.
#
# Deliberately does NOT reuse Ruby's OWN read as the oracle (e.g.
# `PostgresEra#find`/`#all`) — that would only prove "Rust's SQL client
# agrees with Ruby's SQL client reading the SAME compiled view," a
# structurally weaker claim than "Rust agrees with Ruby's own
# independently-computed translation." See mint_and_seed_lineage.rb's
# own header for the full argument, and its compute/rekey sibling for
# the one case where the weaker claim is genuinely the best available.
#
# `io: true` — real I/O (a `cargo build`, two Postgres roles, a mint) —
# excluded locally by default (spec_helper.rb), always run in CI, same
# discipline as every other Postgres/Rust spec.
RSpec.describe "Rust/Ruby lineage parity (rust/host)", io: true do
  RUST_HOST_DIR = File.join(InMemoryDomain::ROOT, "rust", "host")
  SEED_SCRIPT = File.join(RUST_HOST_DIR, "tests", "fixtures", "mint_and_seed_lineage.rb")
  COMPUTE_SEED_SCRIPT = File.join(RUST_HOST_DIR, "tests", "fixtures", "mint_and_seed_lineage_compute.rb")
  MINT_VIA_RUST_SCRIPT = File.join(RUST_HOST_DIR, "tests", "fixtures", "mint_via_rust_matches_ruby.rb")

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?
  end

  # Built once per suite run, not re-checked-out per example — same
  # "trust nothing ambient, build fresh" discipline rust_conformance_
  # spec.rb's own build_rust_for holds the kernel binary to, but a
  # single crate/binary here (no per-domain Cargo feature to select)
  # makes memoizing the one build across examples safe rather than a
  # staleness risk.
  def self.lineage_harness_binary
    return @lineage_harness_binary if defined?(@lineage_harness_binary)

    built = system("cargo", "build", "--bin", "lineage_harness",
                   chdir: RUST_HOST_DIR, out: File::NULL, err: File::NULL)
    binary = File.join(RUST_HOST_DIR, "target", "debug", "lineage_harness")
    @lineage_harness_binary = built && File.executable?(binary) ? binary : nil
  end

  # Same memoization reasoning as `lineage_harness_binary` above — one
  # more binary out of the SAME crate, built once per suite run.
  def self.mint_harness_binary
    return @mint_harness_binary if defined?(@mint_harness_binary)

    built = system("cargo", "build", "--bin", "mint_harness",
                   chdir: RUST_HOST_DIR, out: File::NULL, err: File::NULL)
    binary = File.join(RUST_HOST_DIR, "target", "debug", "mint_harness")
    @mint_harness_binary = built && File.executable?(binary) ? binary : nil
  end

  def drop_scratch!(db_name, owner_role, app_role)
    require "pg"
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{db_name} WITH (FORCE)")
    admin.exec("DROP ROLE IF EXISTS #{owner_role}")
    admin.exec("DROP ROLE IF EXISTS #{app_role}")
    admin.close
  end

  # `capture3`, NOT `capture2`, HERE AND BELOW — a real CI failure
  # (2026-08-26, three merges in a row) raised from `mint_via_rust_
  # matches_ruby.rb failed` with an EMPTY message: `capture2` only ever
  # captured stdout, and a crashing script's own reporting goes to
  # stderr. Reproduced clean locally on the same commit (real Postgres,
  # a correctly-versioned toolchain) — whatever failed in CI wasn't
  # this script's own logic, but `capture2`'s own silence left no way
  # to tell. Whoever hits this next gets the real reason.
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

  it "reads every row lineage_harness reports, connecting as the RLS-fenced app role, matching Ruby's own translated ground truth exactly" do
    binary = self.class.lineage_harness_binary
    skip "cargo build --bin lineage_harness failed" unless binary

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

    # read_by_id, individually, for every row — the generic function's
    # OTHER half (`read_lineage_head_by_id`), not exercised by read_all
    # at all.
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
    skip "cargo build --bin lineage_harness failed" unless binary

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

    # Ruby reads back through its OWN adapter (owner-authenticated, per
    # mint_and_seed_lineage.rb's own comment on why a fresh PostgresEra.
    # new avoids the app role for construction) — proving the write
    # Rust made is durably visible to Ruby's own read path, not just to
    # a second Rust-side read of the same connection.
    require "pg"
    raw = PG.connect("postgres://#{owner_role}@localhost/#{db_name}")
            .exec_params("SELECT state FROM account_head WHERE id = $1", ["written-by-rust"])
    expect(raw.ntuples).to eq(1)
    expect(JSON.parse(raw[0]["state"])).to eq(write_op["state"])
  ensure
    drop_scratch!(db_name, owner_role, app_role) if db_name
  end

  # THE OTHER HALF OF ADR 0029's CLAIM — "every lineage_capable?
  # aggregate," not just a synthetic single-attribute one. Pizzas::Order
  # is a REAL corpus aggregate (examples/pizzas/bluebook/pizzas.bluebook,
  # bound to PostgresEra in examples/pizzas/bluebook/pizzas.hecksagon)
  # with a structurally richer shape the synthetic Ledger fixture above
  # never exercises: a nested value object (Pizza -> Price), a
  # list_of(Topping), and a lifecycle field. No second era here — this
  # aggregate has never drifted, so there is no translation to prove
  # against a second implementation the way the Ledger fixture's write
  # path does; the claim under test is narrower and still real: does
  # the generic read path agree with what Ruby itself wrote, for a
  # shape this rich, through the SAME RLS-fenced app role a production
  # deployment actually reads through.
  #
  # `boot_in_memory.registry.bluebook("Pizzas").aggregate("Order")` —
  # spec_helper.rb's own helper, reused exactly as postgres_era_spec.rb
  # already does: it boots Pizzas bound to Memory, which this test
  # ignores entirely — only the AGGREGATE's declared shape is wanted,
  # not that binding. `LineageManager.check!` (a genuine first-boot
  # hold, era 1) is what actually establishes lineage capability and
  # grants the app role, exactly like mint_and_seed_lineage.rb's own
  # era-1 hold_first! path, just with a real corpus bluebook instead of
  # a synthetic one and role: passed on the FIRST check! call instead
  # of a second mint.
  it "reads a real corpus aggregate (Pizzas::Order) back exactly as Ruby wrote it, through the RLS-fenced app role" do
    binary = self.class.lineage_harness_binary
    skip "cargo build --bin lineage_harness failed" unless binary

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

    results = run_harness(binary, db_name, app_role, "Pizzas", 1, [{ "op" => "read_by_id", "storage_name" => "order", "id" => "p1" }])
    expect(results.first["ok"]).to be(true), results.first["error"]

    # Compared field-by-field, not as one deep #eq — Instance#[] answers
    # a typed Value object, not the plain-JSON shape #to_h/JSON.generate
    # already normalize on the harness side (see the ok:true rows check
    # in the read_all example above for that normalization already
    # proven correct on the synthetic fixture); this asks the narrower,
    # still-real question the DB round-trip alone can answer directly.
    raw = PG.connect(owner_url).exec_params("SELECT state FROM order_head WHERE id = $1", ["p1"])
    expect(raw.ntuples).to eq(1)
    expect(results.first["state"]).to eq(JSON.parse(raw[0]["state"]))
  ensure
    drop_scratch!(db_name, owner_role, app_role) if db_name
  end

  # THE COMPUTE/REKEY CASE — the one migration kind with no in-process
  # Ruby reference implementation anywhere (Ports::Persistence::Lineage#
  # translate's own header names this explicitly), so its only
  # verification is the human-approved sample the real audit records —
  # mint_and_seed_lineage_compute.rb is the first thing in this whole
  # codebase to drive that approval gate for real from outside
  # bin/translation_audit itself, then mint a REAL compute-bearing era
  # on the strength of it. Ground truth here is necessarily Postgres's
  # own compiled SQL, read directly (see that script's own header for
  # why that's the honest bar for this specific case, not a weakening).
  it "reads a compute-migrated era back exactly as Postgres's own compiled SQL produced it, minted only because a real, matching approval was recorded first" do
    binary = self.class.lineage_harness_binary
    skip "cargo build --bin lineage_harness failed" unless binary

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
    # The compute actually ran, not just "the mint succeeded" — every
    # row is genuinely in the POST-compute shape (`doubled`, no
    # leftover `score`), including the two that existed before the
    # mint and were translated by it, not just the one written fresh
    # under era 2.
    expect(rust_rows.map { |_, state| state.keys }).to all(contain_exactly("kind", "doubled"))
  ensure
    drop_scratch!(db_name, owner_role, app_role) if db_name
  end

  # ADR-0030-in-progress step 8 — THE ONE EXAMPLE ABOVE WHERE RUST DOES
  # THE MINTING TOO, not just the reading/writing every earlier example
  # in this file proves. `mint_via_rust_matches_ruby.rb` does BOTH
  # sides itself (own header has the full argument): mints era 1, then
  # era 2 across a real rename edge, independently in Ruby (`Lineage
  # Manager.check!`/`mint!`) and in Rust (`mint_harness`, the actual
  # `bootstrap` boot-gate sequence — `decide_boot_action`,
  # `audit_before_mint`, `mint_era`, not a shortcut), against two
  # separate scratch databases, writing through each language's own
  # real generic write path, then hands back both `account_head` views
  # for this example to diff directly.
  it "mints the same edge independently in Ruby and in Rust and produces byte-identical account_head views" do
    mint_binary = self.class.mint_harness_binary
    skip "cargo build --bin mint_harness failed" unless mint_binary
    read_binary = self.class.lineage_harness_binary
    skip "cargo build --bin lineage_harness failed" unless read_binary

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

  # NOT YET DONE: Compliance::AccountFreezeReview and
  # Compliance::BoxSurrenderReview (examples/compliance/bluebook/
  # compliance.hecksagon:8-9) are the other two real, lineage-capable
  # corpus aggregates — a mechanical extension of the exact pattern
  # just proven above (boot_in_memory-style load, LineageManager.
  # check!, generic read/write, DB round-trip comparison), not a new
  # risk surface Pizzas::Order didn't already cover. Left for whoever
  # next touches this file rather than padded in here for volume alone.
  #
  # ALSO NOT YET DONE: `rekey` specifically. It shares compute's exact
  # approval-gate mechanism (minter.rb's own check treats
  # `!declared.computes.empty? || !declared.rekeys.empty?` as one
  # condition) and mint_and_seed_lineage_compute.rb's approval-recording
  # code already generalizes to it verbatim — only the edge's own rule
  # (`rekey sql: "..."`, recomputing THE AGGREGATE'S IDENTITY rather
  # than one field) and this fixture's `identified_by :kind` domain
  # shape would need to change. Scoped out here as the same kind of
  # low-marginal-value repetition as the two Compliance aggregates
  # above: compute already proves the approval gate holds for real; a
  # rekey fixture would mostly re-prove that same gate a second way.
end

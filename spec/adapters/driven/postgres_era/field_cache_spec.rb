require "hecksagain"
require "tempfile"
require_relative "../../../support/postgres_probe"

# Phase 2 of docs/postgres-era-adapter-split-plan.md: the validation spec
# for Track C (field_cache.rb + resumable_backfill.rb + the retrofitted
# backfill_head_snapshot!). Proves the three things the plan doc requires,
# against a real throwaway Postgres database, never the dev database —
# same pattern every other real-Postgres spec here already uses
# (support/postgres_probe.rb):
#
#   1. cache-table correctness, both before AND after a mint
#   2. backfill resumability under a simulated crash/restart
#   3. genuine non-blocking-ness — a concurrent write succeeds while a
#      backfill is mid-scan
#
# A toy aggregate, purpose-built for this — not routed through Payments
# (~/Projects/junkdrawer/payments), which stays on Heki by its own
# explicit design; this proves a framework capability, not a real domain.
RSpec.describe "PostgresEra field cache — Track C validation",
               io: true do
  FIELD_CACHE_DB = "hecksagain_field_cache_spec".freeze
  FIELD_CACHE_OWNER = "hecksagain_field_cache_owner".freeze

  def owner_url = "postgres://#{FIELD_CACHE_OWNER}@localhost/#{FIELD_CACHE_DB}"

  FIELD_CACHE_V1_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Cache" do
      aggregate "Widget" do
        identified_by :code

        attribute :code, Code
        attribute :status, Status
        attribute :price, Money

        value_object "Code" do
          attribute :value, String
        end

        value_object "Status" do
          attribute :value, String
        end

        value_object "Money" do
          attribute :cents, Integer
        end

        query "ByStatus" do
          where(status: "active")
        end

        query "Costly" do
          where(:"price.cents" => { gt: 500 })
        end
      end
    end
  BLUEBOOK

  # A real shape drift — Track C must keep working across a mint, not
  # merely before one. `status`/`price` survive untouched on purpose: the
  # SAME two declared queries above still apply after the rename, so this
  # proves cache tables carry the id through a rekey-free mint correctly.
  # A REAL SHAPE DRIFT — the aggregate's own name changes (Widget ->
  # Item), which alone is enough to mint a new era (StorageShape's own
  # projection carries the aggregate's identity), while every attribute
  # stays byte-for-byte the same. Deliberately the SMALLEST possible
  # diff: this test is about proving Track C's cache tables survive a
  # mint correctly, not about exercising the translation DSL's rename/
  # move/convert/drop machinery — that's lineage_spec.rb's own job.
  FIELD_CACHE_V2_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Cache" do
      aggregate "Item" do
        identified_by :code

        attribute :code, Code
        attribute :status, Status
        attribute :price, Money

        value_object "Code" do
          attribute :value, String
        end

        value_object "Status" do
          attribute :value, String
        end

        value_object "Money" do
          attribute :cents, Integer
        end

        query "ByStatus" do
          where(status: "active")
        end

        query "Costly" do
          where(:"price.cents" => { gt: 500 })
        end
      end
    end
  BLUEBOOK

  def hash_of(source)
    registry = load_registry(source)
    Hecksagain::Runtime::StorageShape.mint_hash(registry.bluebooks.values.first)
  end

  def label_of(source) = hash_of(source)[0, 6]

  # `from:`/`to:` are ERA LABELS (the first 6 hex chars of the minted
  # shape hash), not raw source text — same convention lineage_spec.rb's
  # own `edge_source(from:, to:)` uses (see its "mints era 2..." example).
  # An empty body — nothing to explain, since no attribute changed.
  def edge_source
    <<~RUBY
      Hecks.data_translation("Cache", from: #{label_of(FIELD_CACHE_V1_SOURCE).inspect}, to: #{label_of(FIELD_CACHE_V2_SOURCE).inspect}) do
        aggregate("Item", was: "Widget") do
        end
      end
    RUBY
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{FIELD_CACHE_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{FIELD_CACHE_DB}")
    admin.exec("DROP ROLE IF EXISTS #{FIELD_CACHE_OWNER}")
    admin.exec("CREATE ROLE #{FIELD_CACHE_OWNER} LOGIN")
    admin.close
    grant = PG.connect(dbname: FIELD_CACHE_DB)
    grant.exec("GRANT CONNECT ON DATABASE #{FIELD_CACHE_DB} TO #{FIELD_CACHE_OWNER}")
    grant.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{FIELD_CACHE_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: FIELD_CACHE_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.exec("GRANT USAGE, CREATE ON SCHEMA public TO #{FIELD_CACHE_OWNER}")
    scrub.close
  end

  def load_registry(source, translation_source: nil)
    registry = Hecksagain::Runtime::Registry.new
    loading = Hecksagain::Ports::Loading.bootstrap
    file = Tempfile.new(["field-cache-", ".bluebook"])
    file.write(source)
    file.flush
    Hecksagain.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      eval(translation_source) if translation_source
    end
    registry
  ensure
    file&.close!
  end

  def check!(source, translation_source: nil)
    registry = load_registry(source, translation_source: translation_source)
    bluebook = registry.bluebooks.values.first
    Hecksagain::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: { database: owner_url }
    )
    registry
  end

  def adapter_for(registry, aggregate_name, era: nil)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    settings = { database: owner_url, domain: "Cache" }
    settings[:era] = era if era
    Hecksagain::Adapters::PostgresEra.new(aggregate: aggregate, settings: settings)
  end

  def instance_for(aggregate, id, status:, cents:)
    Hecksagain::Runtime::Instance.new(
      aggregate: aggregate, id: id,
      state: { code: { "value" => id }, status: { "value" => status }, price: { "cents" => cents } }
    )
  end

  def declared_query(registry, aggregate_name, query_name)
    registry.bluebooks.values.first.aggregate(aggregate_name).queries.find { |q| q.name == query_name }
  end

  def field_cache_table(db, storage_name, era, field)
    name = "hecks_fc_#{Digest::SHA256.hexdigest("#{storage_name}\0#{era}\0#{field}")[0, 20]}"
    db.exec_params("SELECT to_regclass($1) IS NOT NULL AS present", [name])[0]["present"] == "t" ? name : nil
  end

  # ── 1. cache-table correctness, before the mint ──────────────────────

  it "answers a declared where query correctly through the field cache, before any mint" do
    registry = check!(FIELD_CACHE_V1_SOURCE)
    aggregate = registry.bluebooks.values.first.aggregate("Widget")
    adapter = adapter_for(registry, "Widget")

    adapter.save(instance_for(aggregate, "w1", status: "active", cents: 1000))
    adapter.save(instance_for(aggregate, "w2", status: "retired", cents: 200))
    adapter.save(instance_for(aggregate, "w3", status: "active", cents: 300))

    db = PG.connect(dbname: FIELD_CACHE_DB, user: FIELD_CACHE_OWNER)
    expect(field_cache_table(db, "widget", 1, "status")).not_to be_nil
    expect(field_cache_table(db, "widget", 1, "price.cents")).not_to be_nil

    results = adapter.query(declared_query(registry, "Widget", "ByStatus"))
    expect(results.map(&:id)).to contain_exactly("w1", "w3")

    costly = adapter.query(declared_query(registry, "Widget", "Costly"))
    expect(costly.map(&:id)).to contain_exactly("w1")
  ensure
    db&.close
  end

  it "keeps the cache correct across a save that changes the cached field's value" do
    registry = check!(FIELD_CACHE_V1_SOURCE)
    aggregate = registry.bluebooks.values.first.aggregate("Widget")
    adapter = adapter_for(registry, "Widget")

    adapter.save(instance_for(aggregate, "w1", status: "active", cents: 1000))
    expect(adapter.query(declared_query(registry, "Widget", "ByStatus")).map(&:id)).to eq(["w1"])

    adapter.save(instance_for(aggregate, "w1", status: "retired", cents: 1000))
    expect(adapter.query(declared_query(registry, "Widget", "ByStatus")).map(&:id)).to eq([])
  end

  it "removes a deleted id from the cache" do
    registry = check!(FIELD_CACHE_V1_SOURCE)
    aggregate = registry.bluebooks.values.first.aggregate("Widget")
    adapter = adapter_for(registry, "Widget")

    adapter.save(instance_for(aggregate, "w1", status: "active", cents: 1000))
    adapter.delete("w1")
    expect(adapter.query(declared_query(registry, "Widget", "ByStatus")).map(&:id)).to eq([])
  end

  # ── 2. cache-table correctness, after the mint ───────────────────────

  it "answers the same declared query correctly after a real era mint" do
    registry = check!(FIELD_CACHE_V1_SOURCE)
    aggregate1 = registry.bluebooks.values.first.aggregate("Widget")
    adapter1 = adapter_for(registry, "Widget")
    adapter1.save(instance_for(aggregate1, "w1", status: "active", cents: 1000))
    adapter1.save(instance_for(aggregate1, "w2", status: "retired", cents: 900))

    registry2 = check!(FIELD_CACHE_V2_SOURCE, translation_source: edge_source)
    aggregate2 = registry2.bluebooks.values.first.aggregate("Item")
    adapter2 = adapter_for(registry2, "Item", era: 2)

    # w1/w2 survive the rename untranslated in shape (status/price
    # untouched) — the ancestor side of the field-cache backfill (Track
    # C's own union of matview + this era's own snapshot) is what has to
    # get this right; nothing wrote w1/w2 IN era 2 yet.
    ids = adapter2.query(declared_query(registry2, "Item", "ByStatus")).map(&:id)
    expect(ids).to contain_exactly("w1")

    adapter2.save(instance_for(aggregate2, "w3", status: "active", cents: 50))
    ids = adapter2.query(declared_query(registry2, "Item", "ByStatus")).map(&:id)
    expect(ids).to contain_exactly("w1", "w3")
  end

  it "backfills a field cache correctly when the cache table is created against pre-existing history" do
    registry = check!(FIELD_CACHE_V1_SOURCE)
    aggregate = registry.bluebooks.values.first.aggregate("Widget")
    adapter = adapter_for(registry, "Widget")
    adapter.save(instance_for(aggregate, "w1", status: "active", cents: 1000))
    adapter.save(instance_for(aggregate, "w2", status: "active", cents: 200))
    adapter.save(instance_for(aggregate, "w3", status: "retired", cents: 900))

    db = PG.connect(dbname: FIELD_CACHE_DB, user: FIELD_CACHE_OWNER)
    name = field_cache_table(db, "widget", 1, "status")
    db.exec("DROP TABLE #{PG::Connection.quote_ident(name)}")
    db.exec("DELETE FROM hecks_backfill_progress WHERE target = '#{name}'")

    # A fresh adapter instance re-derives the SAME cache table name and
    # must self-heal it — CREATE, then a full chunked backfill sourced
    # from the current head, not an empty table silently matching
    # nothing.
    adapter2 = adapter_for(registry, "Widget")
    ids = adapter2.query(declared_query(registry, "Widget", "ByStatus")).map(&:id)
    expect(ids).to contain_exactly("w1", "w2")
  ensure
    db&.close
  end

  # ── 3. backfill resumability under a simulated crash/restart ─────────

  it "resumes a backfill from its persisted cursor after a simulated crash mid-scan" do
    registry = check!(FIELD_CACHE_V1_SOURCE)
    aggregate = registry.bluebooks.values.first.aggregate("Widget")
    adapter = adapter_for(registry, "Widget")
    ids = (1..10).map { |n| "w#{n}" }
    ids.each { |id| adapter.save(instance_for(aggregate, id, status: "active", cents: 100)) }

    db = PG.connect(dbname: FIELD_CACHE_DB, user: FIELD_CACHE_OWNER)
    name = field_cache_table(db, "widget", 1, "status")
    db.exec("TRUNCATE #{PG::Connection.quote_ident(name)}")
    db.exec("DELETE FROM hecks_backfill_progress WHERE target = '#{name}'")

    stub_const("Hecksagain::Adapters::PostgresEra::Lineage::ResumableBackfill::CHUNK_SIZE", 3)

    attempts = 0
    lineage = Hecksagain::Adapters::PostgresEra::Lineage.new(adapter.instance_variable_get(:@db), "Cache")
    allow(lineage).to receive(:upsert_field_cache_rows!).and_wrap_original do |original, *args|
      attempts += 1
      raise "simulated crash mid-backfill" if attempts == 2

      original.call(*args)
    end

    expression = "state #>> ARRAY['status']::text[]"
    expect { lineage.ensure_field_cache!("widget", 1, "status", expression) }
      .to raise_error(RuntimeError, "simulated crash mid-backfill")

    progress = db.exec_params("SELECT cursor, completed FROM hecks_backfill_progress WHERE target = $1", [name])[0]
    expect(progress["completed"]).to eq("f")
    expect(progress["cursor"]).not_to be_nil
    partial_count = db.exec("SELECT COUNT(*) FROM #{PG::Connection.quote_ident(name)}")[0]["count"].to_i
    expect(partial_count).to be > 0
    expect(partial_count).to be < 10

    # Resume, unstubbed — must pick up from the persisted cursor, not
    # rescan/redo the chunks the first attempt already committed, and
    # must reach full, correct coverage.
    fresh_lineage = Hecksagain::Adapters::PostgresEra::Lineage.new(
      adapter.instance_variable_get(:@db), "Cache"
    )
    fresh_lineage.ensure_field_cache!("widget", 1, "status", expression)

    final_ids = db.exec("SELECT id FROM #{PG::Connection.quote_ident(name)} ORDER BY id").map { |row| row["id"] }
    expect(final_ids).to eq(ids.sort)
  ensure
    db&.close
  end

  # ── 4. genuine non-blocking-ness ──────────────────────────────────────

  it "lets a concurrent plain write through while a backfill is mid-scan" do
    registry = check!(FIELD_CACHE_V1_SOURCE)
    aggregate = registry.bluebooks.values.first.aggregate("Widget")
    adapter = adapter_for(registry, "Widget")
    ids = (1..20).map { |n| "w#{n}" }
    ids.each { |id| adapter.save(instance_for(aggregate, id, status: "active", cents: 100)) }

    db = PG.connect(dbname: FIELD_CACHE_DB, user: FIELD_CACHE_OWNER)
    name = field_cache_table(db, "widget", 1, "status")
    db.exec("TRUNCATE #{PG::Connection.quote_ident(name)}")
    db.exec("DELETE FROM hecks_backfill_progress WHERE target = '#{name}'")
    db.close

    stub_const("Hecksagain::Adapters::PostgresEra::Lineage::ResumableBackfill::CHUNK_SIZE", 2)

    backfill_db = PG.connect(dbname: FIELD_CACHE_DB, user: FIELD_CACHE_OWNER)
    lineage = Hecksagain::Adapters::PostgresEra::Lineage.new(backfill_db, "Cache")
    expression = "state #>> ARRAY['status']::text[]"

    # A slow chunk callback — long enough that, if ANY lock were held
    # across it, a concurrent writer on a SEPARATE connection would
    # visibly stall behind it.
    original = lineage.method(:upsert_field_cache_rows!)
    allow(lineage).to receive(:upsert_field_cache_rows!) do |*args|
      sleep 0.3
      original.call(*args)
    end

    backfill_thread = Thread.new { lineage.ensure_field_cache!("widget", 1, "status", expression) }
    sleep 0.15 # let the backfill get into its first slow chunk

    write_adapter = adapter_for(registry, "Widget")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    write_adapter.save(instance_for(aggregate, "w1", status: "retired", cents: 999))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    backfill_thread.join(10)
    expect(backfill_thread.status).to eq(false) # finished, not still running / not dead-from-error
    expect(elapsed).to be < 1.0 # nowhere near the ~3s the full slow backfill takes end to end
  ensure
    backfill_db&.close
  end
end

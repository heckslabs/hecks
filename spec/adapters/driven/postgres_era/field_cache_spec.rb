require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/thread_parking"

# Field cache and resumable backfill against a throwaway Postgres database:
# correctness before and after a mint, crash resumability, and non-blocking writes.
RSpec.describe "PostgresEra field cache — Track C validation", :io do
  include EraRegistryLoading

  FIELD_CACHE_DB = "hecks_field_cache_spec".freeze
  FIELD_CACHE_OWNER = "hecks_field_cache_owner".freeze

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

  # The smallest shape drift that mints an era: the aggregate is renamed (Widget -> Item)
  # and every attribute is unchanged, so the same queries still apply after the mint.
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
    Hecks::Runtime::StorageShape.mint_hash(registry.bluebooks.values.first)
  end

  def label_of(source) = hash_of(source)[0, 6]

  # `from:`/`to:` are era labels (first 6 hex chars of the minted shape hash).
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

  def check!(source, translation_source: nil)
    registry = load_registry(source, translation_source: translation_source)
    bluebook = registry.bluebooks.values.first
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: { database: owner_url }
    )
    registry
  end

  def adapter_for(registry, aggregate_name, era: nil)
    aggregate = registry.bluebooks.values.first.aggregate(aggregate_name)
    settings = { database: owner_url, domain: "Cache" }
    settings[:era] = era if era
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: settings)
  end

  def instance_for(aggregate, id, status:, cents:)
    Hecks::Runtime::Instance.new(
      aggregate: aggregate, id: id,
      state: { code: { "value" => id }, status: { "value" => status }, price: { "cents" => cents } }
    )
  end

  def declared_query(registry, aggregate_name, query_name)
    registry.bluebooks.values.first.aggregate(aggregate_name).queries.find { |q| q.name == query_name }
  end

  # Calls `Lineage#field_cache` rather than re-deriving the table name, which
  # would drift when the name hash changes (ADR 0059).
  def field_cache_table(db, storage_name, era, field)
    name = Hecks::Adapters::PostgresEra::Lineage.new(db, "Cache").field_cache(storage_name, era, field)
    db.exec_params("SELECT to_regclass($1) IS NOT NULL AS present", [name])[0]["present"] == "t" ? name : nil
  end

  let(:registry) { check!(FIELD_CACHE_V1_SOURCE) }
  let(:aggregate) { registry.bluebooks.values.first.aggregate("Widget") }
  let(:adapter) { adapter_for(registry, "Widget") }

  def save_widget(id, status:, cents:) = adapter.save(instance_for(aggregate, id, status: status, cents: cents))

  # The ids a declared query answers on `store`, which defaults to the era 1 adapter.
  def query_ids(query_name, store: adapter, reg: registry, aggregate_name: "Widget")
    store.query(declared_query(reg, aggregate_name, query_name)).map(&:id)
  end

  def with_owner_db
    db = PG.connect(dbname: FIELD_CACHE_DB, user: FIELD_CACHE_OWNER)
    yield db
  ensure
    db&.close
  end

  # Empties the era 1 status cache and forgets its backfill progress; answers the table's name.
  def empty_status_cache!(db)
    name = field_cache_table(db, "widget", 1, "status")
    db.exec("TRUNCATE #{PG::Connection.quote_ident(name)}")
    db.exec("DELETE FROM hecks_backfill_progress WHERE target = '#{name}'")
    name
  end

  def status_expression = "state #>> ARRAY['status']::text[]"

  def lineage_on_adapter_db = Hecks::Adapters::PostgresEra::Lineage.new(adapter.instance_variable_get(:@db), "Cache")

  context "with three widgets saved" do
    before do
      save_widget("w1", status: "active", cents: 1000)
      save_widget("w2", status: "retired", cents: 200)
      save_widget("w3", status: "active", cents: 300)
    end

    it "caches the fields the declared queries read, before any mint", :aggregate_failures do
      with_owner_db do |db|
        expect(field_cache_table(db, "widget", 1, "status")).not_to be_nil
        expect(field_cache_table(db, "widget", 1, "price.cents")).not_to be_nil
      end
    end

    it "answers a declared where query correctly through the field cache, before any mint" do
      expect(query_ids("ByStatus")).to contain_exactly("w1", "w3")
    end

    it "answers a declared comparison query correctly through the field cache" do
      expect(query_ids("Costly")).to contain_exactly("w1")
    end
  end

  it "keeps the cache correct across a save that changes the cached field's value" do
    save_widget("w1", status: "active", cents: 1000)
    before_change = query_ids("ByStatus")
    save_widget("w1", status: "retired", cents: 1000)

    expect([before_change, query_ids("ByStatus")]).to eq([["w1"], []])
  end

  it "removes a deleted id from the cache" do
    save_widget("w1", status: "active", cents: 1000)
    adapter.delete("w1")

    expect(query_ids("ByStatus")).to eq([])
  end

  context "with a real era mint after two widgets were saved" do
    let(:registry2) { check!(FIELD_CACHE_V2_SOURCE, translation_source: edge_source) }
    let(:adapter2) { adapter_for(registry2, "Item", era: 2) }

    def era_two_ids = query_ids("ByStatus", store: adapter2, reg: registry2, aggregate_name: "Item")

    before do
      save_widget("w1", status: "active", cents: 1000)
      save_widget("w2", status: "retired", cents: 900)
    end

    # nothing wrote w1/w2 in era 2 yet, so the ancestor side of the backfill must supply them
    it "answers the same declared query correctly after the mint" do
      expect(era_two_ids).to contain_exactly("w1")
    end

    it "answers it correctly after a write in the new era too" do
      item = registry2.bluebooks.values.first.aggregate("Item")
      adapter2.save(instance_for(item, "w3", status: "active", cents: 50))

      expect(era_two_ids).to contain_exactly("w1", "w3")
    end
  end

  context "with three widgets saved before the cache table is dropped" do
    before do
      save_widget("w1", status: "active", cents: 1000)
      save_widget("w2", status: "active", cents: 200)
      save_widget("w3", status: "retired", cents: 900)
      with_owner_db { |db| db.exec("DROP TABLE #{PG::Connection.quote_ident(empty_status_cache!(db))}") }
    end

    # a fresh adapter must recreate the table and backfill it from the current head
    it "backfills a field cache correctly when the cache table is created against pre-existing history" do
      expect(query_ids("ByStatus", store: adapter_for(registry, "Widget"))).to contain_exactly("w1", "w2")
    end
  end

  # The resume assertions only mean something against the partial state the simulated crash leaves.
  context "when a backfill crashed mid-scan" do
    def widget_ids = (1..10).map { |n| "w#{n}" }

    # Raises on the second chunk, and lets every other one through.
    def crash_on_second_chunk(lineage)
      attempts = 0
      allow(lineage).to receive(:upsert_field_cache_rows!).and_wrap_original do |original, *args|
        attempts += 1
        raise "simulated crash mid-backfill" if attempts == 2

        original.call(*args)
      end
    end

    def run_crashing_backfill
      stub_const("Hecks::Adapters::PostgresEra::Lineage::ResumableBackfill::CHUNK_SIZE", 3)
      lineage = lineage_on_adapter_db
      crash_on_second_chunk(lineage)
      expect { lineage.ensure_field_cache!("widget", 1, "status", status_expression) }
        .to raise_error(RuntimeError, "simulated crash mid-backfill")
    end

    def backfill_progress(db)
      db.exec_params("SELECT cursor, completed FROM hecks_backfill_progress WHERE target = $1", [@cache_name])[0]
    end

    def cached_count(db) = db.exec("SELECT COUNT(*) FROM #{PG::Connection.quote_ident(@cache_name)}")[0]["count"].to_i

    before do
      widget_ids.each { |id| save_widget(id, status: "active", cents: 100) }
      with_owner_db { |db| @cache_name = empty_status_cache!(db) }
      run_crashing_backfill
    end

    it "records the backfill as incomplete, with a cursor", :aggregate_failures do
      with_owner_db do |db|
        expect(backfill_progress(db)["completed"]).to eq("f")
        expect(backfill_progress(db)["cursor"]).not_to be_nil
      end
    end

    it "leaves the cache partly filled" do
      with_owner_db { |db| expect(cached_count(db)).to be_between(1, 9) }
    end

    # resume unstubbed: continues from the persisted cursor to full coverage
    it "resumes from the persisted cursor to full coverage" do
      lineage_on_adapter_db.ensure_field_cache!("widget", 1, "status", status_expression)

      with_owner_db do |db|
        final = db.exec("SELECT id FROM #{PG::Connection.quote_ident(@cache_name)} ORDER BY id").map { |row| row["id"] }
        expect(final).to eq(widget_ids.sort)
      end
    end
  end

  context "with a slow backfill mid-scan" do
    def slow_down_upserts(lineage, entered)
      # slow enough that a lock held across a chunk would visibly stall the writer
      original = lineage.method(:upsert_field_cache_rows!)
      allow(lineage).to receive(:upsert_field_cache_rows!) do |*args|
        entered << true
        ThreadParking.elapse(0.3)
        original.call(*args)
      end
    end

    def start_slow_backfill(backfill_db, entered)
      stub_const("Hecks::Adapters::PostgresEra::Lineage::ResumableBackfill::CHUNK_SIZE", 2)
      lineage = Hecks::Adapters::PostgresEra::Lineage.new(backfill_db, "Cache")
      slow_down_upserts(lineage, entered)
      Thread.new { lineage.ensure_field_cache!("widget", 1, "status", status_expression) }
    end

    def timed_plain_write
      write_adapter = adapter_for(registry, "Widget")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      write_adapter.save(instance_for(aggregate, "w1", status: "retired", cents: 999))
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    # Writes while a backfill thread is mid-scan; answers the thread's status and the write's
    # duration.
    def write_during_backfill
      backfill_db = PG.connect(dbname: FIELD_CACHE_DB, user: FIELD_CACHE_OWNER)
      entered = Queue.new
      thread = start_slow_backfill(backfill_db, entered)
      ThreadParking.wait_for { !entered.empty? } # the backfill is inside its first slow chunk
      elapsed = timed_plain_write
      thread.join(10)
      [thread.status, elapsed]
    ensure
      backfill_db&.close
    end

    before do
      (1..20).each { |n| save_widget("w#{n}", status: "active", cents: 100) }
      with_owner_db { |db| empty_status_cache!(db) }
    end

    it "lets a concurrent plain write through while a backfill is mid-scan", :aggregate_failures do
      status, elapsed = write_during_backfill

      expect(status).to be(false) # finished, not still running / not dead-from-error
      expect(elapsed).to be < 1.0 # nowhere near the ~3s the full slow backfill takes end to end
    end
  end
end

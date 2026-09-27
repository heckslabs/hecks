require "hecks"
require_relative "../../support/postgres_probe"

# Runs only when a Postgres server is reachable (`support/postgres_probe.rb`).
RSpec.describe Hecks::Adapters::Postgres, :io do
  PLAIN_POSTGRES_SPEC_DB = "hecks_postgres_spec".freeze

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{PLAIN_POSTGRES_SPEC_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{PLAIN_POSTGRES_SPEC_DB}")
    admin.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{PLAIN_POSTGRES_SPEC_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  let(:aggregate) do
    boot_in_memory.registry.bluebook("Pizzas").aggregate("Order")
  end

  let(:adapter) do
    described_class.new(aggregate: aggregate, settings: { database: PLAIN_POSTGRES_SPEC_DB })
  end

  def instance(id, **fields)
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecks::Runtime::Value.for(aggregate, name, value) }
    built
  end

  def indexes_on(db, table)
    db.exec_params("SELECT indexname FROM pg_indexes WHERE tablename = $1", [table]).map { |row| row["indexname"] }
  end

  it "refuses a binding that declares no database" do
    expect { described_class.new(aggregate: aggregate, settings: {}) }
      .to raise_error(Hecks::Runtime::WiringError, /declares no "database"/)
  end

  it "refuses loudly when the declared database is unreachable" do
    expect { described_class.new(aggregate: aggregate, settings: { database: "postgres://localhost:1/nowhere" }) }
      .to raise_error(Hecks::Runtime::WiringError, %r{cannot bind Postgres at postgres://localhost:1/nowhere for Order})
  end

  it "projects its schema as one real typed column per scalar attribute, plus id" do
    adapter
    db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
    columns = db.exec_params(
      "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = $1", ["order"]
    ).to_h { |row| [row["column_name"], row["data_type"]] }
    db.close

    expect(columns["id"]).to eq("text")
    # `status` is a plain text column; the value objects and `toppings` are jsonb.
    expect(columns["status"]).to eq("text")
    expect(columns["name"]).to eq("jsonb")
    expect(columns["pizza"]).to eq("jsonb")
    expect(columns["customer_name"]).to eq("jsonb")
    expect(columns["toppings"]).to eq("jsonb")
  end

  it "saves and finds one back through its own typed columns" do
    adapter.save(instance("p1", name: { value: "Margherita" },
                      pizza: { price_cents: { cents: 1200 }, size: { value: "small" } }, status: "available"))

    found = adapter.find("p1")
    expect(found.name.to_h).to eq(value: "Margherita")
    expect(found.pizza.to_h).to eq(price_cents: { cents: 1200 }, size: { value: "small" })
    expect(found.status).to eq("available")
  end

  it "round-trips a list of value objects through its jsonb column" do
    adapter.save(instance("p1", toppings: [{ name: "Basil", amount: 3 }]))

    toppings = adapter.find("p1").toppings
    expect(toppings).to all(be_a(Hecks::Runtime::Value))
    expect(toppings.map(&:to_h)).to eq([{ name: "Basil", amount: 3 }])
  end

  it "answers nil for an id it never stored" do
    expect(adapter.find("nope")).to be_nil
  end

  it "keeps every write in the append-only log and reads the last one back" do
    adapter.save(instance("p1", status: "available"))
    adapter.save(instance("p1", status: "sold"))

    expect(adapter.count).to eq(1)
    expect(adapter.find("p1").status).to eq("sold")
    expect(adapter.entries.map { |entry| entry.state[:status] }).to eq(%w[available sold])
  end

  it "stores an absent mirrors hash as a real SQL NULL, not the jsonb literal null" do
    adapter.save(instance("p1", status: "available"))

    db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
    null_rows = db.exec_params('SELECT mirrors FROM "order_entries" WHERE mirrors IS NULL')
    expect(null_rows.ntuples).to eq(1)

    jsonb_null_rows = db.exec_params("SELECT mirrors FROM \"order_entries\" WHERE mirrors = 'null'::jsonb")
    expect(jsonb_null_rows.ntuples).to eq(0)
    db.close
  end

  it "still stores a real mirrors hash as jsonb, and reads it back" do
    entry = Hecks::Ports::Persistence::Entry.new(
      operation: "save", id: "p2", state: { status: "available" }, mirrors: { replica: "eu" }
    )
    adapter.append(entry)

    expect(adapter.entries.last.mirrors).to eq("replica" => "eu")

    db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
    row = db.exec_params('SELECT mirrors FROM "order_entries" WHERE aggregate_id = $1', ["p2"])[0]
    db.close
    expect(JSON.parse(row["mirrors"])).to eq("replica" => "eu")
  end

  it "lists everything it holds" do
    adapter.save(instance("p1", name: { value: "Margherita" }))
    adapter.save(instance("p2", name: { value: "Bare" }))

    expect(adapter.all.map(&:id)).to contain_exactly("p1", "p2")
    expect(adapter.count).to eq(2)
  end

  it "deletes through the append-only log and the materialized table" do
    adapter.save(instance("p1", name: { value: "Temporary" }))

    expect(adapter.delete("p1")).to be(true)
    expect(adapter.find("p1")).to be_nil
    expect(adapter.entries.last.operation).to eq("delete")
    expect(adapter.delete("missing")).to be(true)
  end

  it "records and reloads domain events" do
    event = Hecks::Runtime::Event.new(
      name: "PizzaPurchased", aggregate: "Pizza", id: "p1",
      payload: { customer: "c1" }, occurred_at: "2026-01-01T00:00:00Z"
    )
    adapter.record_event(event)

    expect(adapter.events.map { |item| [item.name, item.id, item.payload] })
      .to eq([["PizzaPurchased", "p1", { customer: "c1" }]])
  end

  it "reads back only one record's events, not the whole shared table" do
    adapter.record_event(Hecks::Runtime::Event.new(
                           name: "PizzaPurchased", aggregate: "Pizza", id: "p1",
                           payload: { customer: "c1" }, occurred_at: "2026-01-01T00:00:00Z"
                         ))
    adapter.record_event(Hecks::Runtime::Event.new(
                           name: "PizzaPurchased", aggregate: "Pizza", id: "p2",
                           payload: { customer: "c2" }, occurred_at: "2026-01-01T00:00:01Z"
                         ))
    adapter.record_event(Hecks::Runtime::Event.new(
                           name: "OrderPlaced", aggregate: "Order", id: "p1",
                           payload: { total: 12 }, occurred_at: "2026-01-01T00:00:02Z"
                         ))

    found = adapter.events_for(aggregate: "Pizza", id: "p1")

    expect(found.map { |item| [item.name, item.id, item.payload] })
      .to eq([["PizzaPurchased", "p1", { customer: "c1" }]])
  end

  it "indexes the shared events table by aggregate and aggregate_id" do
    adapter
    db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
    indexes = indexes_on(db, "events")
    db.close

    expect(indexes).to include("hecks_events_aggregate_id_idx")
  end

  it "self-heals its own connection after the backend is killed out from under it, instead of staying dead forever" do
    adapter.save(instance("p1", name: { value: "Margherita" }, status: "sold"))
    victim_pid = adapter.instance_variable_get(:@db).backend_pid

    admin = PG.connect(dbname: "postgres")
    admin.exec_params("SELECT pg_terminate_backend($1)", [victim_pid])
    admin.close

    # The current call still raises; a lost in-flight write is never silently retried.
    expect { adapter.find("p1") }.to raise_error(PG::ConnectionBad)
    # But the connection healed, so the next dispatch is not stuck on a broken handle.
    expect(adapter.find("p1").status).to eq("sold")
  end

  it "outlives the adapter that wrote it" do
    adapter.save(instance("p1", name: { value: "Margherita" }, status: "sold"))

    reopened = described_class.new(aggregate: aggregate, settings: { database: PLAIN_POSTGRES_SPEC_DB })
    expect(reopened.find("p1").status).to eq("sold")
  end

  it "boots twice with no error and no duplicate index" do
    adapter
    db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
    before_indexes = indexes_on(db, "order").sort

    described_class.new(aggregate: aggregate, settings: { database: PLAIN_POSTGRES_SPEC_DB })
    after_indexes = indexes_on(db, "order").sort
    db.close

    expect(after_indexes).to eq(before_indexes)
  end

  it "heals an existing table that predates one of the aggregate's own attributes" do
    adapter # create the table at today's shape
    db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
    # A table committed before `customer_name` was added: `CREATE TABLE IF NOT EXISTS` alone
    # would leave the column missing.
    db.exec('ALTER TABLE "order" DROP COLUMN customer_name')
    db.close

    reopened = described_class.new(aggregate: aggregate, settings: { database: PLAIN_POSTGRES_SPEC_DB })
    reopened.save(instance("p1", name: { value: "Margherita" }, status: "available",
                            customer_name: { value: "Chris" }))

    expect(reopened.find("p1").customer_name.value).to eq("Chris")
  end

  describe "the replay checkpoint (bounds AppendOnly#recover!'s replay to what a restart missed)" do
    it "advances with every project, so entries_since(checkpoint) is empty right after a write" do
      adapter.save(instance("p1", status: "available"))

      expect(adapter.entries_since(adapter.checkpoint)).to eq([])
    end

    it "starts at zero for a table that has never been checkpointed" do
      expect(adapter.checkpoint).to eq(0)
    end

    it "lets entries_since skip everything at or before a given sequence" do
      adapter.save(instance("p1", status: "available"))
      first_checkpoint = adapter.checkpoint
      adapter.save(instance("p2", status: "available"))

      expect(adapter.entries_since(first_checkpoint).map(&:id)).to eq(["p2"])
    end

    it "keeps AppendOnly#recover! from bumping hecks_version when nothing is behind the checkpoint" do
      repository = Hecks::Ports::Persistence::AppendOnly.new(adapter)
      repository.save(instance("p1", status: "available"))
      version_before = repository.find("p1").version

      repository.recover!

      expect(repository.find("p1").version).to eq(version_before)
    end

    it "still catches up a real gap: an entry journaled without being projected is picked up" do
      entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "p1", state: { status: "available" })
      adapter.append(entry)
      expect(adapter.find("p1")).to be_nil

      Hecks::Ports::Persistence::AppendOnly.new(adapter).recover!

      expect(adapter.find("p1").status).to eq("available")
    end
  end

  describe "compact_entries! (deletes old journal rows a :refresh projection no longer needs)" do
    it "starts at zero when nothing has ever been compacted" do
      expect(adapter.compacted_through).to eq(0)
    end

    it "deletes rows at or before through and reports how many, leaving the aggregate table untouched" do
      adapter.save(instance("p1", status: "available"))
      adapter.save(instance("p2", status: "available"))
      through = adapter.checkpoint

      removed = adapter.compact_entries!(through: through)

      expect(removed).to eq(2)
      expect(adapter.entries).to eq([])
      expect(adapter.find("p1").status).to eq("available")
      expect(adapter.compacted_through).to eq(through)
    end

    it "leaves rows after through in the journal" do
      adapter.save(instance("p1", status: "available"))
      first = adapter.checkpoint
      adapter.save(instance("p2", status: "available"))

      adapter.compact_entries!(through: first)

      expect(adapter.entries.map(&:id)).to eq(["p2"])
    end

    it "never moves compacted_through backwards" do
      adapter.save(instance("p1", status: "available"))
      adapter.compact_entries!(through: adapter.checkpoint)
      adapter.save(instance("p2", status: "available"))
      high_water = adapter.checkpoint

      adapter.compact_entries!(through: high_water)
      adapter.compact_entries!(through: 0)

      expect(adapter.compacted_through).to eq(high_water)
    end
  end

  describe "a declared `where`/`order_by` query" do
    it "pushes `CostingLessThan` (a two-level jsonb-nested numeric path) down to SQL, correctly ordered" do
      adapter.save(instance("cheap", name: { value: "Bare" }, pizza: { price_cents: { cents: 300 }, size: { value: "small" } }))
      adapter.save(instance("mid", name: { value: "Basic" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } }))
      adapter.save(instance("pricey", name:  { value: "Loaded" },
                                      pizza: { price_cents: { cents: 1500 }, size: { value: "small" } }))

      # Orders ascending by `order_by :name`: "Bare" < "Basic", so "cheap" sorts before "mid".
      declared = aggregate.query("CostingLessThan")
      expect(adapter.query(declared, { ceiling: { cents: 1000 } }).map(&:id)).to eq(%w[cheap mid])
    end

    it "orders a jsonb-nested numeric member NUMERICALLY, not lexicographically" do
      # As text "900" sorts after "1200"; the ::numeric cast keeps 900 ahead.
      adapter.save(instance("a", name: { value: "A" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } }))
      adapter.save(instance("b", name: { value: "B" }, pizza: { price_cents: { cents: 1200 }, size: { value: "small" } }))
      adapter.save(instance("c", name: { value: "C" }, pizza: { price_cents: { cents: 300 }, size: { value: "small" } }))

      ordered = adapter.all(order_by: :"pizza.price_cents.cents")
      expect(ordered.map(&:id)).to eq(%w[c a b])
    end

    it "orders the lifecycle field's own NATIVE text column correctly, with no cast needed" do
      adapter.save(instance("a", name: { value: "A" }, status: "available"))
      adapter.save(instance("b", name: { value: "B" }, status: "sold"))

      ordered = adapter.all(order_by: :status)
      expect(ordered.map(&:id)).to eq(%w[a b])
    end

    it "creates a plain btree index for the lifecycle field a declared query filters on" do
      adapter
      db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
      indexdefs = db.exec_params("SELECT indexdef FROM pg_indexes WHERE tablename = $1", ["order"]).map { |row| row["indexdef"] }
      db.close

      expect(indexdefs.any? { |sql| sql.include?("(status)") && !sql.include?("#>>") }).to be(true)
    end

    it "creates an expression index reproducing the exact jsonb path a nested query compiles to" do
      adapter
      db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
      indexdefs = db.exec_params("SELECT indexdef FROM pg_indexes WHERE tablename = $1", ["order"]).map { |row| row["indexdef"] }
      db.close

      expect(indexdefs.any? { |sql| sql.include?("pizza") && sql.include?("#>>") && sql.include?("cents") }).to be(true)
    end

    it "attempts no index at all for the list-typed `toppings` attribute" do
      adapter
      db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
      indexdefs = db.exec_params("SELECT indexdef FROM pg_indexes WHERE tablename = $1", ["order"]).map { |row| row["indexdef"] }
      db.close

      expect(indexdefs.none? { |sql| sql.include?("toppings") }).to be(true)
    end
  end

  describe "a `contains` query over a list attribute — no index, still correct" do
    # `toppings` has no single scalar member for `contains`, so this builds a single-field
    # value object directly, as query_agreement_spec.rb does.
    def build_tagged_aggregate
      Hecks::Bluebook::DSL::ConstShim.with(->(const) { const }) do
        Hecks::Bluebook::DSL::AggregateBuilder.new("Widget").tap do |builder|
          builder.value_object("Tag") { attribute :name, String }
          builder.attribute :tags, builder.list_of(Tag)
          builder.query("TaggedRed") { where(tags: { contains: "red" }) }
        end.build
      end
    end

    let(:tagged_aggregate) { build_tagged_aggregate }
    let(:tagged_adapter) { described_class.new(aggregate: tagged_aggregate, settings: { database: PLAIN_POSTGRES_SPEC_DB }) }

    def tagged_instance(id, tags:)
      built = Hecks::Runtime::Instance.new(aggregate: tagged_aggregate, id: id)
      built[:tags] = Hecks::Runtime::Value.for(tagged_aggregate, :tags, tags)
      built
    end

    it "matches by member name via EXISTS + jsonb_array_elements, unaccelerated, with no index on the list column" do
      tagged_adapter.save(tagged_instance("w1", tags: [{ name: "red" }]))
      tagged_adapter.save(tagged_instance("w2", tags: [{ name: "blue" }]))

      declared = tagged_aggregate.query("TaggedRed")
      expect(tagged_adapter.query(declared, {}).map(&:id)).to eq(["w1"])

      db = PG.connect(dbname: PLAIN_POSTGRES_SPEC_DB)
      indexdefs = db.exec_params("SELECT indexdef FROM pg_indexes WHERE tablename = $1", ["widget"]).map { |row| row["indexdef"] }
      db.close
      expect(indexdefs.none? { |sql| sql.include?("tags") }).to be(true)
    end
  end

  it "pushes an 'in' where-clause down to SQL, matching any of the comma-separated list" do
    adapter.save(instance("p1", name: { value: "Margherita" }))
    adapter.save(instance("p2", name: { value: "Diavola" }))
    adapter.save(instance("p3", name: { value: "Bare" }))

    where = Hecks::QuerySpecification::Common::WhereClause.new(
      field: "name", op: :in, value: "Margherita,Diavola"
    )
    declared = Hecks::Bluebook::Query.new(name: "ByName", wheres: [where])

    expect(adapter.query(declared, {}).map(&:id)).to contain_exactly("p1", "p2")
  end

  describe "the optional saga-persistence capability (§2/§3/§4)" do
    it "saves a saga instance and reads it back through each_saga" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1",
                        state: "awaiting_credit", memory: { amount: 100 })

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "awaiting_credit", { amount: 100 }, []]])
    end

    it "upserts on a repeated save for the same (process_manager, correlation)" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "next", memory: { step: 2 })

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "next", { step: 2 }, []]])
    end

    it "deletes a saga instance" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.delete_saga(process_manager: "Onboarding", correlation: "c1")

      expect(adapter.each_saga.to_a).to eq([])
    end

    it "isolates sagas by domain within one shared database" do
      other = described_class.new(aggregate: aggregate, settings: { database: PLAIN_POSTGRES_SPEC_DB, domain: "OtherDomain" })
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      other.save_saga(process_manager: "Onboarding", correlation: "c1", state: "different", memory: {})

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "start", {}, []]])
      expect(other.each_saga.to_a).to eq([["Onboarding", "c1", "different", {}, []]])
    end
  end
end

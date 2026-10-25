require "hecks"
require_relative "../../support/postgres_probe"
require_relative "../../support/scratch_postgres"
require_relative "../../support/persistence_adapter_examples"

# Runs only when a Postgres server is reachable (`support/postgres_probe.rb`).
RSpec.describe Hecks::Adapters::Postgres, :io do
  include_context "with the Pizzas Order adapter helpers"

  PLAIN_POSTGRES_SPEC_DB = "hecks_postgres_spec".freeze

  scratch_postgres PLAIN_POSTGRES_SPEC_DB

  let(:aggregate) do
    boot_in_memory.registry.bluebook("Pizzas").aggregate("Order")
  end

  let(:adapter) do
    described_class.new(aggregate: aggregate, settings: { database: PLAIN_POSTGRES_SPEC_DB })
  end

  def indexes_on(db, table)
    db.exec_params("SELECT indexname FROM pg_indexes WHERE tablename = $1", [table]).map { |row| row["indexname"] }
  end

  def with_db(dbname: PLAIN_POSTGRES_SPEC_DB)
    db = PG.connect(dbname: dbname)
    yield db
  ensure
    db&.close
  end

  def indexdefs_for(table)
    with_db { |db| db.exec_params("SELECT indexdef FROM pg_indexes WHERE tablename = $1", [table]).map { |row| row["indexdef"] } }
  end

  def reopened_adapter = described_class.new(aggregate: aggregate, settings: { database: PLAIN_POSTGRES_SPEC_DB })

  def other_domain_adapter
    described_class.new(aggregate: aggregate, settings: { database: PLAIN_POSTGRES_SPEC_DB, domain: "OtherDomain" })
  end

  def priced_pizza(id, label, cents)
    instance(id, name: { value: label }, pizza: { price_cents: { cents: cents }, size: { value: "small" } })
  end

  it "refuses a binding that declares no database" do
    expect { described_class.new(aggregate: aggregate, settings: {}) }
      .to raise_error(Hecks::Runtime::WiringError, /declares no "database"/)
  end

  it "refuses loudly when the declared database is unreachable" do
    expect { described_class.new(aggregate: aggregate, settings: { database: "postgres://localhost:1/nowhere" }) }
      .to raise_error(Hecks::Runtime::WiringError, %r{cannot bind Postgres at postgres://localhost:1/nowhere for Order})
  end

  def order_column_types
    with_db do |db|
      db.exec_params("SELECT column_name, data_type FROM information_schema.columns WHERE table_name = $1", ["order"])
        .to_h { |row| [row["column_name"], row["data_type"]] }
    end
  end

  it "projects its schema as one real typed column per scalar attribute, plus id" do
    adapter

    # `status` is a plain text column; the value objects and `toppings` are jsonb.
    expect(order_column_types).to include("id" => "text", "status" => "text", "name" => "jsonb", "pizza" => "jsonb",
                                          "customer_name" => "jsonb", "toppings" => "jsonb")
  end

  def mirror_rows(condition)
    with_db { |db| db.exec_params("SELECT mirrors FROM \"order_entries\" WHERE #{condition}").ntuples }
  end

  it "stores an absent mirrors hash as a real SQL NULL, not the jsonb literal null" do
    adapter.save(instance("p1", status: "available"))

    expect([mirror_rows("mirrors IS NULL"), mirror_rows("mirrors = 'null'::jsonb")]).to eq([1, 0])
  end

  context "with a real mirrors hash appended" do
    before do
      entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "p2", state: { status: "available" },
                                                   mirrors: { replica: "eu" })
      adapter.append(entry)
    end

    it "reads it back" do
      expect(adapter.entries.last.mirrors).to eq("replica" => "eu")
    end

    it "still stores it as jsonb" do
      row = with_db { |db| db.exec_params('SELECT mirrors FROM "order_entries" WHERE aggregate_id = $1', ["p2"])[0] }

      expect(JSON.parse(row["mirrors"])).to eq("replica" => "eu")
    end
  end

  it "indexes the shared events table by aggregate and aggregate_id" do
    adapter

    expect(with_db { |db| indexes_on(db, "events") }).to include("hecks_events_aggregate_id_idx")
  end

  def kill_backend_of(store)
    victim_pid = store.instance_variable_get(:@db).backend_pid
    with_db(dbname: "postgres") { |admin| admin.exec_params("SELECT pg_terminate_backend($1)", [victim_pid]) }
  end

  it "self-heals its own connection after the backend is killed out from under it, instead of staying dead forever",
     :aggregate_failures do
    adapter.save(instance("p1", name: { value: "Margherita" }, status: "sold"))
    kill_backend_of(adapter)

    # The current call still raises; a lost in-flight write is never silently retried.
    expect { adapter.find("p1") }.to raise_error(PG::ConnectionBad)
    # But the connection healed, so the next dispatch is not stuck on a broken handle.
    expect(adapter.find("p1").status).to eq("sold")
  end

  def order_indexes = with_db { |db| indexes_on(db, "order").sort }

  it "boots twice with no error and no duplicate index" do
    adapter
    before_indexes = order_indexes

    reopened_adapter

    expect(order_indexes).to eq(before_indexes)
  end

  def drop_customer_name_column
    # A table committed before `customer_name` was added: `CREATE TABLE IF NOT EXISTS` alone
    # would leave the column missing.
    with_db { |db| db.exec('ALTER TABLE "order" DROP COLUMN customer_name') }
  end

  it "heals an existing table that predates one of the aggregate's own attributes" do
    adapter # create the table at today's shape
    drop_customer_name_column
    reopened = reopened_adapter
    reopened.save(instance("p1", name: { value: "Margherita" }, status: "available", customer_name: { value: "Chris" }))

    expect(reopened.find("p1").customer_name.value).to eq("Chris")
  end

  it_behaves_like "a journalled record adapter"
  it_behaves_like "a checkpointed journal adapter"

  it "keeps AppendOnly#recover! from bumping hecks_version when nothing is behind the checkpoint" do
    repository = Hecks::Ports::Persistence::AppendOnly.new(adapter)
    repository.save(instance("p1", status: "available"))
    version_before = repository.find("p1").version

    repository.recover!

    expect(repository.find("p1").version).to eq(version_before)
  end

  describe "a declared `where`/`order_by` query" do
    it "pushes `CostingLessThan` (a two-level jsonb-nested numeric path) down to SQL, correctly ordered" do
      adapter.save(priced_pizza("cheap", "Bare", 300))
      adapter.save(priced_pizza("mid", "Basic", 900))
      adapter.save(priced_pizza("pricey", "Loaded", 1500))

      # Orders ascending by `order_by :name`: "Bare" < "Basic", so "cheap" sorts before "mid".
      expect(adapter.query(aggregate.query("CostingLessThan"), { ceiling: { cents: 1000 } }).map(&:id)).to eq(%w[cheap mid])
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

      expect(indexdefs_for("order").any? { |sql| sql.include?("(status)") && !sql.include?("#>>") }).to be(true)
    end

    it "creates an expression index reproducing the exact jsonb path a nested query compiles to" do
      adapter

      pizza_cents = indexdefs_for("order").any? { |sql| sql.include?("pizza") && sql.include?("#>>") && sql.include?("cents") }

      expect(pizza_cents).to be(true)
    end

    it "attempts no index at all for the list-typed `toppings` attribute" do
      adapter

      expect(indexdefs_for("order").none? { |sql| sql.include?("toppings") }).to be(true)
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

    before do
      tagged_adapter.save(tagged_instance("w1", tags: [{ name: "red" }]))
      tagged_adapter.save(tagged_instance("w2", tags: [{ name: "blue" }]))
    end

    it "matches by member name via EXISTS + jsonb_array_elements, unaccelerated" do
      expect(tagged_adapter.query(tagged_aggregate.query("TaggedRed"), {}).map(&:id)).to eq(["w1"])
    end

    it "has no index on the list column" do
      expect(indexdefs_for("widget").none? { |sql| sql.include?("tags") }).to be(true)
    end
  end

  it "pushes an 'in' where-clause down to SQL, matching any of the comma-separated list" do
    %w[Margherita Diavola Bare].each_with_index { |label, index| adapter.save(instance("p#{index + 1}", name: { value: label })) }
    where = Hecks::QuerySpecification::Common::WhereClause.new(field: "name", op: :in, value: "Margherita,Diavola")

    expect(adapter.query(Hecks::Bluebook::Query.new(name: "ByName", wheres: [where]), {}).map(&:id))
      .to contain_exactly("p1", "p2")
  end

  it_behaves_like "a saga-persisting adapter"
  it_behaves_like "a dispatch-claiming adapter"
end

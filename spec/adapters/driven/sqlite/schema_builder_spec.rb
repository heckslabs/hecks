require "spec_helper"
require "tmpdir"

# Automatic indexing: derived from the aggregate's own declared queries
# (`Pizzas::Order`'s "Available"/"CostingLessThan"/"Expensive" already cover
# a plain scalar, a bare value-object field, and a dotted value-object
# member) plus one fixture from Banking (`CardPayment`'s "Flagged", the only
# `contains`-on-a-list query in the corpus) to prove the one case that must
# NOT get an index. `schema_builder.rb`'s own header comment explains why
# each of these resolves the way it does — this spec proves the SQL text,
# not just that queries still return the right rows.
RSpec.describe "Hecks::Adapters::Sqlite automatic indexing" do
  around do |example|
    @dir = Dir.mktmpdir("hecks-sqlite-indexing-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  before(:context) { @aggregate = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  let(:aggregate) { @aggregate }

  let(:adapter) do
    Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir)
  end

  def db = adapter.instance_variable_get(:@db)

  def index_sql(name)
    db.get_first_value("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", [name])
  end

  def instance(id, **fields)
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecks::Runtime::Value.for(aggregate, name, value) }
    built
  end

  # "Available" declares `where(status: "available")` — status is the
  # lifecycle field, resolved as a plain column the same way any other
  # scalar attribute is (query_expression's own lifecycle special-case).
  it "creates a real btree index for a plain scalar where field" do
    sql = index_sql("idx_order_status")

    expect(sql).to eq(%(CREATE INDEX "idx_order_status" ON "order"("status")))

    # PRAGMA-based proof too, not only the sqlite_master text — belt and
    # braces that SQLite itself considers this a real index on the table,
    # not a string this spec merely asserted about.
    names = db.execute('PRAGMA index_list("order")').map { |row| row["name"] }
    expect(names).to include("idx_order_status")
    columns = db.execute('PRAGMA index_info("idx_order_status")').map { |row| row["name"] }
    expect(columns).to eq(["status"])
  end

  # "Available" also `order_by :name` — name is PizzaName, a value object
  # with a single String member and no numeric one, so query_expression's
  # own fallback lands on the one-field convention "value".
  it "creates an expression index for a bare value-object field, matching what query_expression compiles" do
    sql = index_sql("idx_order_name")

    expect(sql).to eq(%(CREATE INDEX "idx_order_name" ON "order"(json_extract("name", '$.value'))))
  end

  # "CostingLessThan"/"Expensive" both `where(:"pizza.price_cents.cents" => ...)`
  # — a dotted path through a nested value object. The expression text here
  # has to be byte-for-byte what `nested_expression("pizza", ["price_cents", "cents"], nil)`
  # itself would produce, reproduced by calling the same private method
  # `query_expression` calls, not re-derived.
  it "creates an expression index for a dotted value-object member, matching nested_expression exactly" do
    adapter_instance = adapter
    expected = adapter_instance.send(:nested_expression, "pizza", %w[price_cents cents], nil)
    sql = index_sql("idx_order_pizza_price_cents_cents")

    expect(sql).to eq(%(CREATE INDEX "idx_order_pizza_price_cents_cents" ON "order"(#{expected})))
  end

  it "boots without attempting to index the aggregate's own list-typed attribute " \
     "(toppings is never queried, but never indexed either)" do
    adapter
    names = db.execute("SELECT name FROM sqlite_master WHERE type = 'index'").map { |row| row["name"] }

    expect(names.grep(/topping/i)).to eq([])
  end

  it "is idempotent — booting the same database twice creates no duplicate and does not error" do
    adapter
    before_count = db.execute("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'index'").first["n"]

    expect do
      Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir)
    end.not_to raise_error

    reopened_db = SQLite3::Database.new(File.join(@dir, "pizzas.db"))
    after_count = reopened_db.get_first_value("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'")
    expect(after_count).to eq(before_count)
  end

  it "still returns correct results for the queries these indexes were derived from" do
    adapter.save(instance("p1", name: { value: "Margherita" }, pizza: { price_cents: { cents: 900 } }, status: "available"))
    adapter.save(instance("p2", name: { value: "Diavola" }, pizza: { price_cents: { cents: 1500 } }, status: "sold"))
    adapter.save(instance("p3", name: { value: "Bare" }, pizza: { price_cents: { cents: 500 } }, status: "available"))

    available = Hecks::Bluebook::Query.new(
      name:     "Available",
      wheres:   [Hecks::QuerySpecification::Common::WhereClause.new(field: "status", op: :eq, value: "available")],
      order_by: Hecks::QuerySpecification::Common::OrderBy.new(field: "name", direction: :asc)
    )
    expect(adapter.query(available, {}).map(&:id)).to eq(%w[p3 p1])

    costing_less_than = Hecks::Bluebook::Query.new(
      name:     "CostingLessThan",
      wheres:   [Hecks::QuerySpecification::Common::WhereClause.new(field: "pizza.price_cents.cents", op: :lt, value: 1000)],
      order_by: Hecks::QuerySpecification::Common::OrderBy.new(field: "name", direction: :asc)
    )
    expect(adapter.query(costing_less_than, {}).map(&:id)).to eq(%w[p3 p1])
  end

  describe "a list-typed field (Banking::CardPayment's `tags`, the corpus's one `contains`-on-a-list query)" do
    BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR

    def boot_banking
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        load_bluebook_files(BANKING_BLUEBOOK)
        Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
      end
    end

    it "attempts no index at all, and boots clean" do
      card_payment = boot_banking.registry.bluebook("Banking").aggregate("CardPayment")

      card_payment_adapter = nil
      expect do
        card_payment_adapter = Hecks::Adapters::Sqlite.new(
          aggregate: card_payment, settings: { database: "card_payment.db" }, root: @dir
        )
      end.not_to raise_error

      names = card_payment_adapter.instance_variable_get(:@db)
                                  .execute("SELECT name FROM sqlite_master WHERE type = 'index'")
                                  .map { |row| row["name"] }
      expect(names.grep(/tag/i)).to eq([])
      # "Pending"/"Disputed" both `where(status: ...)` — the lifecycle
      # field still gets its own plain index, same as Order's.
      expect(names).to include("idx_card_payment_status")
    end
  end
end

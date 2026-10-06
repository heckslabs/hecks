require "spec_helper"
require "tmpdir"

# Automatic indexing derived from the aggregate's own declared queries, plus Banking's
# `CardPayment` "Flagged" (`contains` on a list) as the one case that must not get an index.
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

  def pragma_names(sql) = db.execute(sql).map { |row| row["name"] }

  # `status` is the lifecycle field; it resolves as a plain column like any scalar.
  it "creates a real btree index for a plain scalar where field" do
    expect(index_sql("idx_order_status")).to eq(%(CREATE INDEX "idx_order_status" ON "order"("status")))
  end

  # The PRAGMA check confirms SQLite itself sees a real index, not just the sqlite_master text.
  it "makes the plain scalar's index visible to SQLite's own PRAGMAs", :aggregate_failures do
    expect(pragma_names('PRAGMA index_list("order")')).to include("idx_order_status")
    expect(pragma_names('PRAGMA index_info("idx_order_status")')).to eq(["status"])
  end

  # PizzaName has no numeric member, so the expression falls back to the "value" convention.
  it "creates an expression index for a bare value-object field, matching what query_expression compiles" do
    sql = index_sql("idx_order_name")

    expect(sql).to eq(%(CREATE INDEX "idx_order_name" ON "order"(json_extract("name", '$.value'))))
  end

  # A dotted path through a nested value object; the text must equal what `query_expression`
  # gets from calling `nested_expression("pizza", ["price_cents", "cents"], nil)`.
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

  def reopen_adapter
    Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir)
  end

  def index_count(database)
    database.get_first_value("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'")
  end

  it "is idempotent — booting the same database twice creates no duplicate and does not error", :aggregate_failures do
    adapter
    before_count = index_count(db)

    expect { reopen_adapter }.not_to raise_error
    expect(index_count(SQLite3::Database.new(File.join(@dir, "pizzas.db")))).to eq(before_count)
  end

  def pizza(ref, name, cents, status)
    instance(ref, name: { value: name }, pizza: { price_cents: { cents: cents }, size: { value: "small" } }, status: status)
  end

  # A query over `field`, ordered by name.
  def pizza_query(name, field, operator, value)
    Hecks::Bluebook::Query.new(
      name:     name,
      wheres:   [Hecks::QuerySpecification::Common::WhereClause.new(field: field, op: operator, value: value)],
      order_by: Hecks::QuerySpecification::Common::OrderBy.new(field: "name", direction: :asc)
    )
  end

  context "with three pizzas saved" do
    before do
      adapter.save(pizza("p1", "Margherita", 900, "available"))
      adapter.save(pizza("p2", "Diavola", 1500, "sold"))
      adapter.save(pizza("p3", "Bare", 500, "available"))
    end

    it "still returns correct results for the query an index was derived from on status" do
      expect(adapter.query(pizza_query("Available", "status", :eq, "available"), {}).map(&:id)).to eq(%w[p3 p1])
    end

    it "still returns correct results for the query an index was derived from on a nested member" do
      costing_less_than = pizza_query("CostingLessThan", "pizza.price_cents.cents", :lt, 1000)

      expect(adapter.query(costing_less_than, {}).map(&:id)).to eq(%w[p3 p1])
    end
  end

  describe "a list-typed field (Banking::CardPayment's `tags`, the corpus's one `contains`-on-a-list query)" do
    BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR unless defined?(BANKING_BLUEBOOK)

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

    let(:card_payment_adapter) do
      card_payment = boot_banking.registry.bluebook("Banking").aggregate("CardPayment")
      Hecks::Adapters::Sqlite.new(aggregate: card_payment, settings: { database: "card_payment.db" }, root: @dir)
    end

    def index_names
      card_payment_adapter.instance_variable_get(:@db)
                          .execute("SELECT name FROM sqlite_master WHERE type = 'index'")
                          .map { |row| row["name"] }
    end

    it "attempts no index at all, and boots clean" do
      expect { card_payment_adapter }.not_to raise_error
    end

    it "indexes nothing for the list" do
      expect(index_names.grep(/tag/i)).to eq([])
    end

    # The lifecycle field gets its own plain index, as on Order.
    it "gives the lifecycle field its own plain index" do
      expect(index_names).to include("idx_card_payment_status")
    end
  end
end

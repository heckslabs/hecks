require "spec_helper"
require "sqlite3"

RSpec.describe "D1 execution-plan capabilities" do
  def item_aggregate
    Hecksagain::Bluebook::DSL::BluebookBuilder.build("D1Planning") do
      vision "D1 implements the same atomic-put contract as Memory and SQLite"

      aggregate "Item" do
        identified_by do
          attribute :sku, String
        end

        value_object("Label") { attribute :value, String }
        attribute :label, Label
      end
    end.aggregate("Item")
  end

  def fake_batch_connection
    Class.new do
      attr_reader :batches

      def initialize
        @batches = []
        @ids = {}
      end

      def execute(*)
        raise "atomic_put must use one batch, not independent execute calls"
      end

      def batch(statements)
        @batches << statements
        id = statements.fetch(0).fetch(1).fetch(0).to_s
        status = @ids.key?(id) ? "replaced" : "inserted"
        @ids[id] = true
        [[{ "status" => status }], [], []]
      end
    end.new
  end

  def adapter_with(connection, aggregate)
    Hecksagain::Adapters::D1.allocate.tap do |adapter|
      adapter.instance_variable_set(:@aggregate, aggregate)
      adapter.instance_variable_set(:@db, connection)
    end
  end

  it "uses one transactional batch and reports the database-classified insert or replacement outcome" do
    aggregate = item_aggregate
    connection = fake_batch_connection
    repository = Hecksagain::Ports::Persistence::AppendOnly.new(adapter_with(connection, aggregate))

    first = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate,
      id:        "sku-1",
      state:     { identity: { sku: "sku-1" }, label: { value: "First" } }
    )
    second = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate,
      id:        "sku-1",
      state:     { identity: { sku: "sku-1" }, label: { value: "Second" } }
    )

    expect(repository.capabilities).to eq([:atomic_put])
    expect(repository.atomic_put(first).status).to eq(:inserted)
    expect(repository.atomic_put(second).status).to eq(:replaced)

    expect(connection.batches.size).to eq(2)
    connection.batches.each do |statements|
      expect(statements.size).to eq(3)
      expect(statements[0][0]).to match(/SELECT CASE WHEN EXISTS .* AS status/)
      expect(statements[1][0]).to include('INSERT INTO "item_entries"')
      expect(statements[2][0]).to include('INSERT OR REPLACE INTO "item"')
    end
  end

  # `real_sqlite_batch_connection` runs each statement against a genuine
  # SQLite3::Database, inside `@db.transaction`, in the SAME order — the
  # local proxy for what Connection#batch's own comment says D1 already
  # guarantees server-side ("statements execute in order and a failure
  # rolls the entire sequence back"). `fake_batch_connection` above only
  # proves the RUBY SIDE issues one batch and no separate `execute`; this
  # proves the SQL ITSELF is valid and the `WHERE NOT EXISTS` gating
  # genuinely blocks both writes when the row already exists — not just
  # that the code compiles. A real multi-threaded concurrency test (the
  # shape `postgres_atomic_put_spec.rb` uses) is not attempted here: two
  # Ruby threads sharing ONE SQLite3::Database connection are not a
  # faithful stand-in for D1's own server-side concurrent-batch handling,
  # and would test SQLite3-gem thread-safety more than the SQL's own
  # correctness. What actually closed the gap — moving the check inside
  # the same atomic batch instead of a separate round trip — is exactly
  # what this test exercises.
  def real_sqlite_batch_connection
    db = SQLite3::Database.new(":memory:")
    db.results_as_hash = true
    Class.new do
      def initialize(db) = @db = db

      def execute(sql, binds = []) = @db.execute(sql, binds)
      def get_first_row(sql, binds = []) = execute(sql, binds).first
      def get_first_value(sql, binds = []) = get_first_row(sql, binds)&.values&.first

      def batch(statements)
        results = nil
        @db.transaction { results = statements.map { |sql, binds| execute(sql, binds || []) } }
        results
      end
    end.new(db)
  end

  def adapter_on_real_sqlite(aggregate)
    connection = real_sqlite_batch_connection
    adapter = adapter_with(connection, aggregate)
    %i[create_aggregate_table! create_entry_table! ensure_entry_operation_column! ensure_entry_mirrors_column!].each do |setup|
      adapter.send(setup)
    end
    adapter
  end

  it "insert_only: closes the round trip — one batch, and a real conflict blocks both writes" do
    aggregate = item_aggregate
    adapter = adapter_on_real_sqlite(aggregate)
    repository = Hecksagain::Ports::Persistence::AppendOnly.new(adapter)

    first = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate, id: "sku-1", state: { identity: { sku: "sku-1" }, label: { value: "First" } }
    )
    second = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate, id: "sku-1", state: { identity: { sku: "sku-1" }, label: { value: "Second" } }
    )

    expect(repository.atomic_put(first, insert_only: true).status).to eq(:inserted)
    expect(adapter.entries.size).to eq(1)
    expect(adapter.find("sku-1").state[:label].to_h).to eq(value: "First")

    # THE ROW ALREADY EXISTS — both gated writes must be genuine no-ops,
    # not merely "the method returns :conflicted while quietly still
    # writing," which is precisely the shape the old separate-round-trip
    # check could not rule out under a real race.
    expect(repository.atomic_put(second, insert_only: true).status).to eq(:conflicted)
    expect(adapter.entries.size).to eq(1)
    expect(adapter.find("sku-1").state[:label].to_h).to eq(value: "First")
  end

  it "insert_only: still issues exactly one batch, no separate existence-check round trip" do
    aggregate = item_aggregate
    connection = fake_batch_connection
    repository = Hecksagain::Ports::Persistence::AppendOnly.new(adapter_with(connection, aggregate))

    instance = Hecksagain::Runtime::Instance.new(
      aggregate: aggregate, id: "sku-1", state: { identity: { sku: "sku-1" }, label: { value: "First" } }
    )

    repository.atomic_put(instance, insert_only: true)

    expect(connection.batches.size).to eq(1)
    statements = connection.batches.first
    expect(statements.size).to eq(3)
    expect(statements[0][0]).to match(/SELECT CASE WHEN EXISTS .* THEN 'conflicted' ELSE 'inserted' END AS status/)
    expect(statements[1][0]).to include("WHERE NOT EXISTS")
    expect(statements[2][0]).to include("WHERE NOT EXISTS")
  end

  it "encodes the connection batch as one REST request and returns each statement's rows in order" do
    connection = Hecksagain::Adapters::D1::Connection.new(
      account_id:  "account",
      database_id: "database",
      api_token:   "token"
    )
    response = double(
      code: "200",
      body: JSON.generate(
        success: true,
        result:  [
          { success: true, results: [{ status: "inserted" }] },
          { success: true, results: [] }
        ]
      )
    )
    http = double
    payload = nil

    allow(http).to receive(:request) do |request|
      payload = JSON.parse(request.body)
      response
    end
    allow(Net::HTTP).to receive(:start) { |*, &block| block.call(http) }

    rows = connection.batch([
                              ["SELECT ? AS status", ["inserted"]],
                              ["INSERT INTO items (id) VALUES (?)", ["sku-1"]]
                            ])

    expect(payload).to eq(
      "batch" => [
        { "sql" => "SELECT ? AS status", "params" => ["inserted"] },
        { "sql" => "INSERT INTO items (id) VALUES (?)", "params" => ["sku-1"] }
      ]
    )
    expect(rows).to eq([[{ "status" => "inserted" }], []])
  end
end

require "spec_helper"
require "sqlite3"

RSpec.describe "D1 execution-plan capabilities" do
  def item_aggregate
    Hecks::Bluebook::DSL::BluebookBuilder.build("D1Planning") do
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
    Hecks::Adapters::D1.allocate.tap do |adapter|
      adapter.instance_variable_set(:@aggregate, aggregate)
      adapter.instance_variable_set(:@db, connection)
    end
  end

  it "uses one transactional batch and reports the database-classified insert or replacement outcome" do
    aggregate = item_aggregate
    connection = fake_batch_connection
    repository = Hecks::Ports::Persistence::AppendOnly.new(adapter_with(connection, aggregate))

    first = Hecks::Runtime::Instance.new(
      aggregate: aggregate,
      id:        "sku-1",
      state:     { identity: { sku: "sku-1" }, label: { value: "First" } }
    )
    second = Hecks::Runtime::Instance.new(
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

  # Runs each statement in a real SQLite3::Database inside a transaction, in order: the local
  # stand-in for D1's server-side batch atomicity. Shows the SQL is valid and that the
  # `WHERE NOT EXISTS` gating blocks both writes. No threaded race test: two threads on one
  # SQLite3 connection would test the gem's thread-safety, not D1's batch handling.
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
    repository = Hecks::Ports::Persistence::AppendOnly.new(adapter)

    first = Hecks::Runtime::Instance.new(
      aggregate: aggregate, id: "sku-1", state: { identity: { sku: "sku-1" }, label: { value: "First" } }
    )
    second = Hecks::Runtime::Instance.new(
      aggregate: aggregate, id: "sku-1", state: { identity: { sku: "sku-1" }, label: { value: "Second" } }
    )

    expect(repository.atomic_put(first, insert_only: true).status).to eq(:inserted)
    expect(adapter.entries.size).to eq(1)
    expect(adapter.find("sku-1").state[:label].to_h).to eq(value: "First")

    # The row already exists: both gated writes must be real no-ops, not a `:conflicted`
    # return that still writes.
    expect(repository.atomic_put(second, insert_only: true).status).to eq(:conflicted)
    expect(adapter.entries.size).to eq(1)
    expect(adapter.find("sku-1").state[:label].to_h).to eq(value: "First")
  end

  it "insert_only: still issues exactly one batch, no separate existence-check round trip" do
    aggregate = item_aggregate
    connection = fake_batch_connection
    repository = Hecks::Ports::Persistence::AppendOnly.new(adapter_with(connection, aggregate))

    instance = Hecks::Runtime::Instance.new(
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

  it "binds a real NULL, not the JSON text \"null\", for an absent mirrors hash" do
    aggregate = item_aggregate
    connection = fake_batch_connection
    repository = Hecks::Ports::Persistence::AppendOnly.new(adapter_with(connection, aggregate))

    instance = Hecks::Runtime::Instance.new(
      aggregate: aggregate, id: "sku-1", state: { identity: { sku: "sku-1" }, label: { value: "First" } }
    )
    repository.atomic_put(instance)

    entry_binds = connection.batches.first[1][1]
    expect(entry_binds).to include(nil)
    expect(entry_binds).not_to include("null")
  end

  it "stores an absent mirrors hash as a real SQL NULL through atomic_put's own batch, queryable via IS NULL" do
    aggregate = item_aggregate
    adapter = adapter_on_real_sqlite(aggregate)
    repository = Hecks::Ports::Persistence::AppendOnly.new(adapter)

    instance = Hecks::Runtime::Instance.new(
      aggregate: aggregate, id: "sku-1", state: { identity: { sku: "sku-1" }, label: { value: "First" } }
    )
    repository.atomic_put(instance)

    connection = adapter.instance_variable_get(:@db)
    expect(connection.get_first_row('SELECT mirrors FROM "item_entries" WHERE mirrors IS NULL')).not_to be_nil
    expect(connection.execute("SELECT mirrors FROM \"item_entries\" WHERE mirrors = 'null'")).to be_empty
  end

  it "stores an absent mirrors hash as a real SQL NULL through plain #append too" do
    aggregate = item_aggregate
    adapter = adapter_on_real_sqlite(aggregate)

    entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "sku-1", state: { identity: { sku: "sku-1" } })
    adapter.append(entry)

    connection = adapter.instance_variable_get(:@db)
    expect(connection.get_first_row('SELECT mirrors FROM "item_entries" WHERE mirrors IS NULL')).not_to be_nil
  end

  # One mocked HTTP round trip, asserted twice: the request sent and the rows parsed back.
  # rubocop:disable-next RSpec/ExampleLength
  it "encodes the connection batch as one REST request and returns each statement's rows in order" do
    connection = Hecks::Adapters::D1::Connection.new(
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

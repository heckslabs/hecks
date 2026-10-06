require "spec_helper"
require "sqlite3"

RSpec.describe "D1 execution-plan capabilities" do
  # A connection that answers `batch` the way D1 classifies it, and refuses independent `execute`s.
  class D1FakeBatchConnection
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
  end

  # Runs each statement in a real SQLite3::Database inside a transaction, in order: the local
  # stand-in for D1's server-side batch atomicity. Shows the SQL is valid and that the
  # `WHERE NOT EXISTS` gating blocks both writes. No threaded race test: two threads on one
  # SQLite3 connection would test the gem's thread-safety, not D1's batch handling.
  class D1RealSqliteBatchConnection
    def initialize(db) = @db = db

    def execute(sql, binds = []) = @db.execute(sql, binds)
    def get_first_row(sql, binds = []) = execute(sql, binds).first
    def get_first_value(sql, binds = []) = get_first_row(sql, binds)&.values&.first

    def batch(statements)
      results = nil
      @db.transaction { results = statements.map { |sql, binds| execute(sql, binds || []) } }
      results
    end
  end

  D1_BATCH_STATEMENTS = [
    ["SELECT ? AS status", ["inserted"]],
    ["INSERT INTO items (id) VALUES (?)", ["sku-1"]]
  ].freeze

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

  def adapter_with(connection, aggregate)
    Hecks::Adapters::D1.allocate.tap do |adapter|
      adapter.instance_variable_set(:@aggregate, aggregate)
      adapter.instance_variable_set(:@db, connection)
    end
  end

  def real_sqlite_batch_connection
    db = SQLite3::Database.new(":memory:")
    db.results_as_hash = true
    D1RealSqliteBatchConnection.new(db)
  end

  def adapter_on_real_sqlite(aggregate)
    adapter = adapter_with(real_sqlite_batch_connection, aggregate)
    %i[create_aggregate_table! create_entry_table! ensure_entry_operation_column! ensure_entry_mirrors_column!].each do |setup|
      adapter.send(setup)
    end
    adapter
  end

  def item_labelled(label)
    Hecks::Runtime::Instance.new(
      aggregate: aggregate, id: "sku-1", state: { identity: { sku: "sku-1" }, label: { value: label } }
    )
  end

  let(:aggregate) { item_aggregate }
  let(:connection) { fake_batch_connection }
  let(:repository) { Hecks::Ports::Persistence::AppendOnly.new(adapter_with(connection, aggregate)) }

  def fake_batch_connection = D1FakeBatchConnection.new

  describe "the fake batch connection" do
    def put_twice = [repository.atomic_put(item_labelled("First")), repository.atomic_put(item_labelled("Second"))]

    it "reports the one capability it has" do
      expect(repository.capabilities).to eq([:atomic_put])
    end

    it "reports the database-classified insert, then replacement, outcome" do
      expect(put_twice.map(&:status)).to eq(%i[inserted replaced])
    end

    it "uses one transactional batch for each put" do
      put_twice

      expect(connection.batches.size).to eq(2)
    end

    it "shapes each batch as an existence check, an entry insert and a snapshot replace" do
      put_twice

      expect(connection.batches.map { |statements| statements.map(&:first) }).to all(
        match([match(/SELECT CASE WHEN EXISTS .* AS status/), a_string_including('INSERT INTO "item_entries"'),
               a_string_including('INSERT OR REPLACE INTO "item"')])
      )
    end

    context "with insert_only" do
      let(:statements) { connection.batches.first }

      before { repository.atomic_put(item_labelled("First"), insert_only: true) }

      it "still issues exactly one batch, no separate existence-check round trip" do
        expect(connection.batches.size).to eq(1)
      end

      it "checks for a conflict in the same batch", :aggregate_failures do
        expect(statements.size).to eq(3)
        expect(statements[0][0]).to match(/SELECT CASE WHEN EXISTS .* THEN 'conflicted' ELSE 'inserted' END AS status/)
      end

      it "gates both writes on the row not existing", :aggregate_failures do
        expect(statements[1][0]).to include("WHERE NOT EXISTS")
        expect(statements[2][0]).to include("WHERE NOT EXISTS")
      end
    end

    it "binds a real NULL, not the JSON text \"null\", for an absent mirrors hash", :aggregate_failures do
      repository.atomic_put(item_labelled("First"))

      entry_binds = connection.batches.first[1][1]
      expect(entry_binds).to include(nil)
      expect(entry_binds).not_to include("null")
    end
  end

  describe "a real SQLite3 database behind the batch" do
    let(:real_adapter) { adapter_on_real_sqlite(aggregate) }
    let(:real_repository) { Hecks::Ports::Persistence::AppendOnly.new(real_adapter) }

    def real_db = real_adapter.instance_variable_get(:@db)

    context "with the first insert_only put made" do
      before { real_repository.atomic_put(item_labelled("First"), insert_only: true) }

      it "insert_only: closes the round trip — one batch holding the first write", :aggregate_failures do
        expect(real_adapter.entries.size).to eq(1)
        expect(real_adapter.find("sku-1").state[:label].to_h).to eq(value: "First")
      end

      # The row already exists: both gated writes must be real no-ops, not a `:conflicted`
      # return that still writes.
      it "insert_only: a real conflict blocks both writes", :aggregate_failures do
        status = real_repository.atomic_put(item_labelled("Second"), insert_only: true).status

        expect(status).to eq(:conflicted)
        expect(real_adapter.entries.size).to eq(1)
        expect(real_adapter.find("sku-1").state[:label].to_h).to eq(value: "First")
      end
    end

    it "stores an absent mirrors hash as a real SQL NULL through atomic_put's own batch, queryable via IS NULL",
       :aggregate_failures do
      real_repository.atomic_put(item_labelled("First"))

      expect(real_db.get_first_row('SELECT mirrors FROM "item_entries" WHERE mirrors IS NULL')).not_to be_nil
      expect(real_db.execute("SELECT mirrors FROM \"item_entries\" WHERE mirrors = 'null'")).to be_empty
    end

    it "stores an absent mirrors hash as a real SQL NULL through plain #append too" do
      entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "sku-1", state: { identity: { sku: "sku-1" } })
      real_adapter.append(entry)

      expect(real_db.get_first_row('SELECT mirrors FROM "item_entries" WHERE mirrors IS NULL')).not_to be_nil
    end
  end

  # One mocked HTTP round trip, asserted twice: the request sent and the rows parsed back.
  describe "the REST connection" do
    let(:payloads) { [] }
    let(:rows) { d1_connection.batch(D1_BATCH_STATEMENTS) }

    def d1_connection
      Hecks::Adapters::D1::Connection.new(account_id: "account", database_id: "database", api_token: "token")
    end

    def batch_response
      body = JSON.generate(success: true, result: [{ success: true, results: [{ status: "inserted" }] },
                                                   { success: true, results: [] }])
      double(code: "200", body: body)
    end

    before do
      http = double
      allow(http).to receive(:request) do |request|
        payloads << JSON.parse(request.body)
        batch_response
      end
      allow(Net::HTTP).to receive(:start) { |*, &block| block.call(http) }
    end

    it "encodes the connection batch as one REST request" do
      rows

      expect(payloads).to eq(
        [{ "batch" => [{ "sql" => "SELECT ? AS status", "params" => ["inserted"] },
                       { "sql" => "INSERT INTO items (id) VALUES (?)", "params" => ["sku-1"] }] }]
      )
    end

    it "returns each statement's rows in order" do
      expect(rows).to eq([[{ "status" => "inserted" }], []])
    end
  end
end

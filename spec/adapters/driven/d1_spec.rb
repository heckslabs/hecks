require "spec_helper"
require "sqlite3"

# D1 talks the same dialect as Sqlite over an HTTP transport
# (Adapters::D1::Connection) — these specs replace that transport with a
# real in-memory SQLite3::Database (same shape `d1/execution_plan_spec.rb`'s
# own `real_sqlite_batch_connection` already uses) so `initialize`'s own
# settings-parsing runs for real with no network call involved.
RSpec.describe Hecks::Adapters::D1 do
  def aggregate
    Hecks::Bluebook::DSL::BluebookBuilder.build("D1Settings") do
      vision "D1's own settings parsing is exercised with no real HTTP transport"

      aggregate("Item") do
        identified_by { attribute :sku, String }
      end
    end.aggregate("Item")
  end

  def fake_connection
    db = SQLite3::Database.new(":memory:")
    db.results_as_hash = true
    Class.new do
      def initialize(db) = @db = db
      def execute(sql, binds = []) = @db.execute(sql, binds)
      def get_first_row(sql, binds = []) = execute(sql, binds).first
      def get_first_value(sql, binds = []) = get_first_row(sql, binds)&.values&.first
    end.new(db)
  end

  before do
    allow(described_class::Connection).to receive(:new).and_return(fake_connection)
  end

  # `settings[:domain] || settings["domain"] || aggregate.name` used to
  # coerce a genuinely stored `false` at :domain into the `aggregate.name`
  # fallback — indistinguishable from :domain being absent entirely. `false`
  # is not a realistic domain name, but it is exactly the shape the fix
  # (`key?`-gated, not `||`-gated) must get right: present-but-falsy reads
  # back as itself, not as the fallback.
  it "reads a `false`-valued :domain setting back as itself, not the aggregate-name fallback" do
    adapter = described_class.new(
      aggregate: aggregate,
      settings:  { account_id: "acc", database_id: "db", api_token: "tok", domain: false }
    )

    expect(adapter.instance_variable_get(:@domain)).to eq("false")
  end

  it "still falls back to the aggregate's own name when :domain is genuinely absent" do
    adapter = described_class.new(
      aggregate: aggregate,
      settings:  { account_id: "acc", database_id: "db", api_token: "tok" }
    )

    expect(adapter.instance_variable_get(:@domain)).to eq("Item")
  end

  it "prefers a symbol-keyed :account_id over a string-keyed one, even when the symbol value is falsy" do
    # `||` would have silently used the STRING key's value here instead
    # (`false` at :account_id treated as if absent). Asserting on the exact
    # args `Connection.new` receives is what actually proves the fixed
    # `key?`-gated read, not just that construction happened to succeed.
    # rubocop:disable-next RSpec/StubbedMock -- see comment above
    expect(described_class::Connection).to receive(:new)
      .with(account_id: false, database_id: "db", api_token: "tok")
      .and_return(fake_connection)

    described_class.new(
      aggregate: aggregate,
      settings:  { account_id: false, "account_id" => "should-not-be-used", database_id: "db", api_token: "tok" }
    )
  end
end

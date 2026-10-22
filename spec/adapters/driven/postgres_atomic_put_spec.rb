require "hecks"
require_relative "../../support/postgres_probe"
require_relative "../../support/persistence_adapter_examples"

RSpec.describe "Postgres atomic_put persistence", :io do
  include_context "with the atomic_put Item aggregate"

  SCHEMA = "hecks_atomic_put_spec".freeze

  def database
    ENV["POSTGRES_URL"].to_s.empty? ? "postgres" : ENV.fetch("POSTGRES_URL")
  end

  # A bare dbname is not a conninfo string: `PG.connect(database)` would treat it as a host.
  # Mirrors the adapter's own `connect_for` branching.
  def pg_connect
    database.start_with?("postgres://", "postgresql://") ? PG.connect(database) : PG.connect(dbname: database)
  end

  def postgres_available?
    return PostgresProbe.available? if ENV["POSTGRES_URL"].to_s.empty?

    require "pg"
    PG.connect(ENV.fetch("POSTGRES_URL")).close
    true
  rescue LoadError, PG::Error
    false
  end

  before(:all) do
    skip "no reachable Postgres — set POSTGRES_URL or start one to run this spec" unless postgres_available?

    @postgres_atomic_put_available = true
  end

  before do
    connection = pg_connect
    connection.exec("DROP SCHEMA IF EXISTS #{PG::Connection.quote_ident(SCHEMA)} CASCADE")
    connection.exec("CREATE SCHEMA #{PG::Connection.quote_ident(SCHEMA)}")
    connection.close
  end

  after(:all) do
    next unless @postgres_atomic_put_available

    connection = pg_connect
    connection.exec("DROP SCHEMA IF EXISTS #{PG::Connection.quote_ident(SCHEMA)} CASCADE")
    connection.close
  end

  def repository(aggregate)
    adapter = Hecks::Adapters::Postgres.new(
      aggregate: aggregate,
      settings:  { database: database, schema: SCHEMA }
    )
    Hecks::Ports::Persistence::AppendOnly.new(adapter)
  end

  let(:aggregate) { item_aggregate("PostgresPlanning", "Postgres implements the atomic-put execution contract") }
  let(:store) { repository(aggregate) }

  it "reports the capabilities it has" do
    expect(store.capabilities).to eq(%i[atomic_put optimistic_concurrency])
  end

  it_behaves_like "an atomic_put adapter"

  # One writer that waits for `start` before it puts, so both writers put at the same moment.
  def racing_writer(stored, label, ready, start)
    Thread.new do
      ready << true
      start.pop
      stored.atomic_put(item_labelled(label)).status
    end
  end

  # Releases two writers at once; answers what each one's put reported.
  def put_concurrently(stores)
    ready = Queue.new
    start = Queue.new
    threads = stores.zip(%w[First Second]).map { |stored, label| racing_writer(stored, label, ready, start) }
    2.times { ready.pop }
    2.times { start << true }
    threads.map(&:value)
  ensure
    threads&.each { |thread| thread.join if thread.alive? }
  end

  it "serializes concurrent first writers so exactly one observes insertion", :aggregate_failures do
    stores = [repository(aggregate), repository(aggregate)]

    expect(put_concurrently(stores)).to contain_exactly(:inserted, :replaced)
    expect(stores.first.entries.size).to eq(2)
    expect(stores.first.find("sku-1").state[:label].to_h.fetch(:value)).to(satisfy { |value| %w[First Second].include?(value) })
  end

  it "rolls the journal append back when projection fails", :aggregate_failures do
    store.adapter.define_singleton_method(:project) { |_entry| raise "projection failed" }

    expect { store.atomic_put(item_labelled("Never committed")) }.to raise_error(RuntimeError, "projection failed")
    expect(store.entries).to be_empty
    expect(store.find("sku-1")).to be_nil
  end
end

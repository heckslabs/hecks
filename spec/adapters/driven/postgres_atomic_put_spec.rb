require "hecks"
require_relative "../../support/postgres_probe"

RSpec.describe "Postgres atomic_put persistence", io: true do
  SCHEMA = "hecks_atomic_put_spec".freeze

  def database
    ENV["POSTGRES_URL"].to_s.empty? ? "postgres" : ENV.fetch("POSTGRES_URL")
  end

  # A bare dbname ("postgres", the local default) is not a conninfo string —
  # PG.connect(database) alone hands it to libpq as a HOST, not a database
  # name, and fails to resolve. Same dual-branch declared.start_with?(...)
  # PG.connect(declared) : PG.connect(dbname: declared) the real adapter
  # under test already uses (lib/hecks/adapters/driven/postgres.rb
  # .connect_for) for the exact same POSTGRES_URL-or-local-default shape.
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

  def item_aggregate
    Hecks::Bluebook::DSL::BluebookBuilder.build("PostgresPlanning") do
      vision "Postgres implements the atomic-put execution contract"

      aggregate "Item" do
        identified_by do
          attribute :sku, String
        end

        value_object("Label") { attribute :value, String }
        attribute :label, Label
      end
    end.aggregate("Item")
  end

  def repository(aggregate)
    adapter = Hecks::Adapters::Postgres.new(
      aggregate: aggregate,
      settings:  { database: database, schema: SCHEMA }
    )
    Hecks::Ports::Persistence::AppendOnly.new(adapter)
  end

  def item(aggregate, label)
    Hecks::Runtime::Instance.new(
      aggregate: aggregate,
      id:        "sku-1",
      state:     { identity: { sku: "sku-1" }, label: { value: label } }
    )
  end

  it "atomically appends and projects while reporting insert versus replacement" do
    aggregate = item_aggregate
    stored = repository(aggregate)

    expect(stored.capabilities).to eq(%i[atomic_put optimistic_concurrency])
    expect(stored.atomic_put(item(aggregate, "First")).status).to eq(:inserted)
    expect(stored.atomic_put(item(aggregate, "Second")).status).to eq(:replaced)
    expect(stored.entries.size).to eq(2)
    expect(stored.find("sku-1").state[:label].to_h).to eq(value: "Second")
  end

  it "serializes concurrent first writers so exactly one observes insertion" do
    aggregate = item_aggregate
    stores = [repository(aggregate), repository(aggregate)]
    ready = Queue.new
    start = Queue.new

    threads = stores.zip(%w[First Second]).map do |stored, label|
      Thread.new do
        ready << true
        start.pop
        stored.atomic_put(item(aggregate, label)).status
      end
    end
    2.times { ready.pop }
    2.times { start << true }

    expect(threads.map(&:value)).to contain_exactly(:inserted, :replaced)
    expect(stores.first.entries.size).to eq(2)
    expect(stores.first.find("sku-1").state[:label].to_h.fetch(:value))
      .to(satisfy { |value| %w[First Second].include?(value) })
  ensure
    threads&.each { |thread| thread.join if thread.alive? }
  end

  it "rolls the journal append back when projection fails" do
    aggregate = item_aggregate
    stored = repository(aggregate)
    stored.adapter.define_singleton_method(:project) { |_entry| raise "projection failed" }

    expect { stored.atomic_put(item(aggregate, "Never committed")) }
      .to raise_error(RuntimeError, "projection failed")
    expect(stored.entries).to be_empty
    expect(stored.find("sku-1")).to be_nil
  end
end

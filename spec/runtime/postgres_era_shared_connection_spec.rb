require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"
require_relative "../support/fenced_owner"

# A domain's PostgresEra adapters share one connection per database and schema, so booting a
# domain with many aggregates does not exhaust the server's connection slots.
RSpec.describe "PostgresEra shares one connection across a domain's aggregates", :io do
  SHARED_CONN_DB = "hecks_shared_connection_spec".freeze
  AGGREGATE_COUNT = 70

  def owner_url = FencedOwner.url(SHARED_CONN_DB)

  def connections_to_spec_database
    admin = PG.connect(dbname: "postgres")
    admin.exec_params(
      "SELECT count(*) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
      [SHARED_CONN_DB]
    )[0]["count"].to_i
  ensure
    admin&.close
  end

  PG_ERA_THING_BODY = proc do
    value_object("Name") { attribute :value, String }
    attribute :name, Name
    identified_by :name
  end

  def many_aggregate_domain(count)
    Hecks.bluebook "Sprawl" do
      vision "Many aggregates, one connection."
      core

      count.times { |index| aggregate("Thing#{index}", &PG_ERA_THING_BODY) }
    end
  end

  def save_flow_saga(adapter)
    adapter.with_write_lock do
      adapter.save_saga(process_manager: "Flow", correlation: "c1", state: "open", memory: { n: 1 })
    end
  end

  def terminate_connections
    admin = PG.connect(dbname: "postgres")
    admin.exec_params(
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
      [SHARED_CONN_DB]
    )
    admin.close
  end

  def hold_write_lock(adapter, inside, release)
    adapter.with_write_lock do
      inside << true
      release.pop
      raise "abort"
    end
  rescue RuntimeError
    nil
  end

  # Runs a statement on one adapter while another's write lock is held open.
  #
  # @return [Array] whether the statement was still blocked mid-lock, and its answer afterward
  def count_while_write_lock_held(holder_adapter, other_adapter)
    inside = Queue.new
    release = Queue.new
    holder = Thread.new { hold_write_lock(holder_adapter, inside, release) }
    inside.pop
    other = Thread.new { other_adapter.count }
    sleep 0.2
    blocked = other.alive?
    release << true
    holder.join
    [blocked, other.value]
  end

  def adapters_for(domain, settings)
    domain.aggregates.map do |aggregate|
      Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: settings.merge(domain: "Sprawl"))
    end
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SHARED_CONN_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{SHARED_CONN_DB}")
    admin.close
    FencedOwner.own!(SHARED_CONN_DB)
  end

  after(:all) do
    Hecks::Adapters::PostgresSharedConnection.close_all!
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SHARED_CONN_DB} WITH (FORCE)")
    admin.close
  end

  before do
    Hecks::Adapters::PostgresSharedConnection.close_all!
    scrub = PG.connect(dbname: SHARED_CONN_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    FencedOwner.own_public!(SHARED_CONN_DB)
  end

  after { Hecks::Adapters::PostgresSharedConnection.close_all! }

  around do |example|
    Hecks.with_registry(Hecks::Runtime::Registry.new) { example.run }
  end

  it "holds a handful of connections however many aggregates boot", :aggregate_failures do
    adapters = adapters_for(many_aggregate_domain(AGGREGATE_COUNT), database: owner_url)

    expect(adapters.size).to eq(AGGREGATE_COUNT)
    expect(connections_to_spec_database).to be <= 3
    expect(Hecks::Adapters::PostgresSharedConnection.open_count).to eq(1)
  end

  it "keeps the shared connection working: one adapter reads what another wrote", :aggregate_failures do
    first, second = adapters_for(many_aggregate_domain(2), database: owner_url)
    save_flow_saga(first)

    expect(second.each_saga.to_a).to eq([["Flow", "c1", "open", { n: 1 }, []]])
    expect(second.count).to eq(0)
  end

  it "gives a different schema its own connection" do
    domain = many_aggregate_domain(2)
    adapters_for(domain, database: owner_url)
    adapters_for(domain, database: owner_url, schema: "tenant_b")

    expect(Hecks::Adapters::PostgresSharedConnection.open_count).to eq(2)
  end

  it "does not let one thread's statements join another thread's transaction", :aggregate_failures do
    first, second = adapters_for(many_aggregate_domain(2), database: owner_url)

    blocked, value = count_while_write_lock_held(first, second)

    expect(blocked).to be(true)
    expect(value).to eq(0)
  end

  it "replaces a dead connection once for every adapter that trips on it", :aggregate_failures do
    adapters = adapters_for(many_aggregate_domain(3), database: owner_url)
    terminate_connections

    expect { adapters.first.pg_exec("SELECT 1") }.to raise_error(PG::Error)
    expect(adapters.map(&:count)).to eq([0, 0, 0])
    expect(connections_to_spec_database).to be <= 2
  end
end

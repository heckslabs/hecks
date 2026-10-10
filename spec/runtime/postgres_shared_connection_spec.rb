require "spec_helper"
require "hecks/adapters/driven/postgres"
require_relative "../support/postgres_probe"
require_relative "../support/fenced_owner"
require_relative "../support/thread_parking"

# A domain's plain Postgres adapters share one connection per database and schema, so booting a
# domain with many aggregates does not exhaust the server's connection slots.
RSpec.describe "Postgres shares one connection across a domain's aggregates", :io do
  PG_SHARED_CONN_DB = "hecks_pg_shared_conn_spec".freeze
  PG_AGGREGATE_COUNT = 70

  def owner_url = FencedOwner.url(PG_SHARED_CONN_DB)

  def connections_to_spec_database
    admin = PG.connect(dbname: "postgres")
    admin.exec_params(
      "SELECT count(*) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
      [PG_SHARED_CONN_DB]
    )[0]["count"].to_i
  ensure
    admin&.close
  end

  PG_THING_BODY = proc do
    value_object("Name") { attribute :value, String }
    attribute :name, Name
    identified_by :name
  end

  def many_aggregate_domain(count)
    Hecks.bluebook "Sprawl" do
      vision "Many aggregates, one connection."
      core

      count.times { |index| aggregate("Thing#{index}", &PG_THING_BODY) }
    end
  end

  def backend_pid(adapter) = adapter.pg_exec("SELECT pg_backend_pid()")[0]["pg_backend_pid"]

  def terminate_connections
    admin = PG.connect(dbname: "postgres")
    admin.exec_params(
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
      [PG_SHARED_CONN_DB]
    )
    admin.close
  end

  # Plain Postgres does not create the schema it is pointed at.
  def create_tenant_schema
    scrub = PG.connect(owner_url)
    scrub.exec("CREATE SCHEMA tenant_b")
    scrub.close
  end

  def hold_transaction(adapter, inside, release)
    adapter.send(:transaction) do
      inside << true
      release.pop
      raise "abort"
    end
  rescue RuntimeError
    nil
  end

  # Runs a statement on one adapter while another's transaction is held open.
  #
  # @return [Array] whether the statement was still blocked mid-transaction, and its answer afterward
  def count_while_transaction_open(holder_adapter, other_adapter)
    inside = Queue.new
    release = Queue.new
    holder = Thread.new { hold_transaction(holder_adapter, inside, release) }
    inside.pop
    other = Thread.new { other_adapter.count }
    ThreadParking.wait_until_parked(other)
    blocked = other.alive?
    release << true
    holder.join
    [blocked, other.value]
  end

  def exit_status_of_forked_boot(domain)
    child = fork do
      adapters_for(domain, database: owner_url).each(&:count)
      GC.start
      exit(0)
    end
    Process.wait2(child).last
  end

  def adapters_for(domain, settings)
    domain.aggregates.map do |aggregate|
      Hecks::Adapters::Postgres.new(aggregate: aggregate, settings: settings.merge(domain: "Sprawl"))
    end
  end

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{PG_SHARED_CONN_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{PG_SHARED_CONN_DB}")
    admin.close
    FencedOwner.own!(PG_SHARED_CONN_DB)
  end

  after(:all) do
    Hecks::Adapters::PostgresSharedConnection.close_all!
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{PG_SHARED_CONN_DB} WITH (FORCE)")
    admin.close
  end

  before do
    Hecks::Adapters::PostgresSharedConnection.close_all!
    scrub = PG.connect(dbname: PG_SHARED_CONN_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    FencedOwner.own_public!(PG_SHARED_CONN_DB)
  end

  after { Hecks::Adapters::PostgresSharedConnection.close_all! }

  around do |example|
    Hecks.with_registry(Hecks::Runtime::Registry.new) { example.run }
  end

  it "holds a handful of connections however many aggregates boot", :aggregate_failures do
    adapters = adapters_for(many_aggregate_domain(PG_AGGREGATE_COUNT), database: owner_url)

    expect(adapters.size).to eq(PG_AGGREGATE_COUNT)
    expect(connections_to_spec_database).to be <= 3
    expect(Hecks::Adapters::PostgresSharedConnection.open_count).to eq(1)
  end

  it "keeps the shared connection working: one adapter reads what another wrote", :aggregate_failures do
    first, second = adapters_for(many_aggregate_domain(2), database: owner_url)
    first.save_saga(process_manager: "Flow", correlation: "c1", state: "open", memory: { n: 1 })

    expect(second.each_saga.to_a).to eq([["Flow", "c1", "open", { n: 1 }, []]])
    expect(second.count).to eq(0)
  end

  it "gives a different schema its own connection" do
    domain = many_aggregate_domain(2)
    create_tenant_schema
    adapters_for(domain, database: owner_url)
    adapters_for(domain, database: owner_url, schema: "tenant_b")

    expect(Hecks::Adapters::PostgresSharedConnection.open_count).to eq(2)
  end

  it "does not let one thread's statements join another thread's transaction", :aggregate_failures do
    first, second = adapters_for(many_aggregate_domain(2), database: owner_url)

    blocked, value = count_while_transaction_open(first, second)

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

  describe "a forked child" do
    let(:domain) { many_aggregate_domain(2) }
    let(:adapters) { adapters_for(domain, database: owner_url) }

    it "keeps the parent's connection alive when it boots adapters and exits", :aggregate_failures do
      parent_pid = backend_pid(adapters.first)

      expect(exit_status_of_forked_boot(domain).success?).to be(true)
      expect(adapters.map(&:count)).to eq([0, 0])
      expect(backend_pid(adapters.first)).to eq(parent_pid)
    end
  end
end

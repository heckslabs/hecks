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

  def many_aggregate_domain(count)
    Hecks.bluebook "Sprawl" do
      vision "Many aggregates, one connection."
      core

      count.times do |index|
        aggregate "Thing#{index}" do
          value_object("Name") { attribute :value, String }
          attribute :name, Name
          identified_by :name
        end
      end
    end
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

  it "holds a handful of connections however many aggregates boot" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      adapters = adapters_for(many_aggregate_domain(AGGREGATE_COUNT), database: owner_url)

      expect(adapters.size).to eq(AGGREGATE_COUNT)
      expect(connections_to_spec_database).to be <= 3
      expect(Hecks::Adapters::PostgresSharedConnection.open_count).to eq(1)
    end
  end

  it "keeps the shared connection working: one adapter reads what another wrote" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      first, second = adapters_for(many_aggregate_domain(2), database: owner_url)
      first.with_write_lock do
        first.save_saga(process_manager: "Flow", correlation: "c1", state: "open", memory: { n: 1 })
      end

      expect(second.each_saga.to_a).to eq([["Flow", "c1", "open", { n: 1 }, []]])
      expect(second.count).to eq(0)
    end
  end

  it "gives a different schema its own connection" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      domain = many_aggregate_domain(2)
      adapters_for(domain, database: owner_url)
      adapters_for(domain, database: owner_url, schema: "tenant_b")

      expect(Hecks::Adapters::PostgresSharedConnection.open_count).to eq(2)
    end
  end

  it "does not let one thread's statements join another thread's transaction" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      first, second = adapters_for(many_aggregate_domain(2), database: owner_url)
      inside = Queue.new
      release = Queue.new
      holder = Thread.new do
        first.with_write_lock do
          inside << true
          release.pop
          raise "abort"
        end
      rescue RuntimeError
        nil
      end
      inside.pop
      other = Thread.new { second.count }
      sleep 0.2
      expect(other.alive?).to be(true)
      release << true
      holder.join

      expect(other.value).to eq(0)
    end
  end

  it "replaces a dead connection once for every adapter that trips on it" do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      adapters = adapters_for(many_aggregate_domain(3), database: owner_url)
      admin = PG.connect(dbname: "postgres")
      admin.exec_params(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
        [SHARED_CONN_DB]
      )
      admin.close

      expect { adapters.first.pg_exec("SELECT 1") }.to raise_error(PG::Error)
      expect(adapters.map(&:count)).to eq([0, 0, 0])
      expect(connections_to_spec_database).to be <= 2
    end
  end
end

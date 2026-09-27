require "hecks"
require "securerandom"
require "tmpdir"
require_relative "../support/postgres_probe"

RSpec.describe Hecks::Ports::Persistence::PostgresDump do
  let(:error) { described_class::Error }

  describe Hecks::Ports::Persistence::PostgresDump::Connection do
    it "splits a URL into the settings and environment libpq wants, decoding the password" do
      connection = described_class.new("postgres://app:p%40ss@db.example:5433/site?sslmode=require")

      expect(connection.env).to eq("PGHOST" => "db.example", "PGPORT" => "5433", "PGUSER" => "app", "PGPASSWORD" => "p@ss",
                                   "PGDATABASE" => "site", "PGSSLMODE" => "require")
    end

    it "swaps the database and keeps everything else" do
      swapped = described_class.new("postgres://app:pw@db.example/site").with_database("scratch")

      expect(swapped.database).to eq("scratch")
      expect(swapped.env).to include("PGHOST" => "db.example", "PGUSER" => "app", "PGPASSWORD" => "pw")
    end

    it "accepts a URL with no host, as a local socket connection" do
      expect(described_class.new("postgres:///site").env).to eq("PGDATABASE" => "site")
    end

    it "refuses anything that is not a postgres URL" do
      expect { described_class.new("mysql://x/y") }
        .to raise_error(Hecks::Ports::Persistence::PostgresDump::Error, /not a postgres URL/)
    end
  end

  it "refuses a schema name that is not a plain identifier" do
    expect { described_class.new(url: "postgres://localhost/x", schema: "a;drop") }
      .to raise_error(error, /plain identifier/)
  end

  it "explains a table that disagrees between source and restore" do
    message = described_class.allocate.send(:mismatch, { "events" => 3, "gone" => 1 }, { "events" => 2 })

    expect(message).to include("events (source 3, restored 2)", "gone (source 1, restored nil)", "dump it again")
  end

  describe "the tools it runs" do
    let(:dump) { described_class.new(url: "postgres://app:hunter2@db.example/site", schema: "site1") }
    let(:connection) { described_class::Connection.new("postgres://app:hunter2@db.example/site") }

    it "hands the password over in the environment and never in the arguments" do
      status = instance_double(Process::Status, success?: true)
      expect(Open3).to receive(:capture3) do |env, tool, *args|
        expect(env).to include("PGPASSWORD" => "hunter2", "PGUSER" => "app")
        expect(([tool] + args).join(" ")).not_to include("hunter2")
        ["", "", status]
      end

      dump.send(:run, "pg_dump", connection, "--schema=site1")
    end

    it "reports a tool that is not installed" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect { dump.send(:run, "pg_dump", connection) }.to raise_error(error, /pg_dump is not on PATH/)
    end

    it "reports a tool that fails, from its own first lines" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(["", "pg_dump: error: boom\ndetail\n", status])

      expect { dump.send(:run, "pg_dump", connection) }.to raise_error(error, /pg_dump failed: pg_dump: error: boom/)
    end
  end

  describe "against a real database", :io do
    let(:names) { [] }

    before do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?
      skip "pg_dump and pg_restore are not on PATH" unless %w[pg_dump pg_restore].all? { |tool| on_path?(tool) }
    end

    after { names.each { |name| drop_database(name) } }

    def on_path?(tool)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, tool)) }
    end

    def admin
      PG.connect(dbname: "postgres")
    end

    def drop_database(name)
      connection = admin
      connection.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
    ensure
      connection&.close
    end

    # A fresh database with schema `site1` (events: 3 rows, registrations: 2) and an unrelated schema.
    def seeded_url
      name = "hecks_dump_spec_#{SecureRandom.hex(4)}"
      names << name
      connection = admin
      connection.exec("CREATE DATABASE #{name}")
      connection.close
      seeded = PG.connect(dbname: name)
      seeded.exec(<<~SQL)
        CREATE SCHEMA site1;
        CREATE TABLE site1.events (id serial PRIMARY KEY, name text);
        INSERT INTO site1.events (name) VALUES ('a'), ('b'), ('c');
        CREATE TABLE site1.registrations (id serial PRIMARY KEY, event_id integer);
        INSERT INTO site1.registrations (event_id) VALUES (1), (2);
        CREATE SCHEMA other;
        CREATE TABLE other.noise (id serial PRIMARY KEY);
      SQL
      seeded.close
      "postgres:///#{name}"
    end

    def leftover_scratch_databases
      connection = admin
      connection.exec("SELECT datname FROM pg_database WHERE datname LIKE 'dump_verify_#{Process.pid}_%'")
                .map { |row| row["datname"] }
    ensure
      connection&.close
    end

    it "dumps one schema, proves it restores, and returns the row counts" do
      Dir.mktmpdir do |dir|
        dump = File.join(dir, "site.dump")

        result = described_class.new(url: seeded_url, schema: "site1").call(dump)

        expect(result.tables).to eq("events" => 3, "registrations" => 2)
        expect(File.size(dump)).to be_positive
        expect(leftover_scratch_databases).to be_empty
      end
    end

    it "dumps only the schema asked for" do
      Dir.mktmpdir do |dir|
        dump = File.join(dir, "site.dump")
        described_class.new(url: seeded_url, schema: "site1").call(dump)

        listing, = Open3.capture2("pg_restore", "--list", dump)

        expect(listing).to include("events", "registrations")
        expect(listing).not_to include("noise")
      end
    end

    it "refuses a schema that has no tables" do
      Dir.mktmpdir do |dir|
        expect { described_class.new(url: seeded_url, schema: "nope").call(File.join(dir, "x.dump")) }
          .to raise_error(error, /schema nope has no tables/)
      end
    end

    it "refuses a database it cannot reach, without echoing the password" do
      Dir.mktmpdir do |dir|
        unreachable = described_class.new(url: "postgres://nobody:hunter2@127.0.0.1:1/x", schema: "s")

        expect { unreachable.call(File.join(dir, "x.dump")) }
          .to raise_error(error) { |failure| expect(failure.message).not_to include("hunter2") }
      end
    end
  end
end

require "spec_helper"
require_relative "../../../lib/hecks/hecks/adapters/pg_admin"

# The PgAdmin port's adapter administers roles and scratch databases; a fake connection answers
# from tables so the statements it sends can be checked without a server.
RSpec.describe Hecks::Adapters::PgAdmin do
  # Answers queries from a hash keyed by a fragment of the SQL and records every statement.
  class FakePgConnection
    Rows = Struct.new(:rows) do
      include Enumerable

      def ntuples = rows.size
      def [](index) = rows[index]
      def each(&) = rows.each(&)
    end

    attr_reader :statements, :closed

    def initialize(dbname, answers, log)
      @dbname = dbname
      @answers = answers
      @statements = log
    end

    def exec(sql) = record(sql)

    def exec_params(sql, params) = record(sql, params)

    def quote_ident(name) = %("#{name}")

    def close = (@closed = true)

    private

    def record(sql, params = nil)
      @statements << [@dbname, sql.strip.gsub(/\s+/, " "), params]
      key = @answers.keys.find { |fragment| sql.include?(fragment) }
      Rows.new(key ? @answers[key] : [])
    end
  end

  let(:log) { [] }
  let(:answers) { {} }
  let(:admin) { described_class.new }

  before do
    described_class.connector = ->(dbname:) { FakePgConnection.new(dbname, answers, log) }
  end

  after { described_class.connector = nil }

  def sql = log.map { |entry| entry[1] }

  describe "#create_ledger_role" do
    let(:answers) do
      { "FROM pg_roles" => [], "FROM pg_database" => [{ "owner" => "postgres" }],
        "FROM pg_namespace" => [{ "owner" => "postgres" }] }
    end

    it "creates the role, takes over the database and the schema, and says how to bind it" do
      report = admin.create_ledger_role(database: { value: "ledger" })[:report][:value]

      expect(sql).to include(a_string_matching(/CREATE ROLE "hecks_qa" LOGIN NOSUPERUSER NOBYPASSRLS/))
      expect(sql).to include('ALTER DATABASE "ledger" OWNER TO "hecks_qa"')
      expect(sql).to include('ALTER SCHEMA public OWNER TO "hecks_qa"')
      expect(report).to include("created role hecks_qa").and include("bind it: database \"postgres://hecks_qa@localhost/ledger\"")
    end

    it "moves each relation and function to the role, by the keyword its kind takes" do
      answers["FROM pg_class"] = [{ "relname" => "events", "relkind" => "r", "owner" => "me" },
                                  { "relname" => "seq", "relkind" => "S", "owner" => "me" }]
      answers["FROM pg_proc"] = [{ "proname" => "fence", "args" => "text", "owner" => "me" }]

      report = admin.create_ledger_role(database: "ledger", role: "auditor")[:report][:value]

      expect(sql).to include('ALTER TABLE "events" OWNER TO "auditor"', 'ALTER SEQUENCE "seq" OWNER TO "auditor"',
                             'ALTER FUNCTION "fence"(text) OWNER TO "auditor"')
      expect(report).to include("2 relation(s) in public").and include("1 function(s) in public")
    end

    it "changes nothing when the role already owns the database and is ordinary" do
      answers["FROM pg_roles"] = [{ "rolsuper" => "f", "rolbypassrls" => "f" }]
      answers["FROM pg_database"] = [{ "owner" => "hecks_qa" }]
      answers["FROM pg_namespace"] = [{ "owner" => "hecks_qa" }]

      report = admin.create_ledger_role(database: "ledger")[:report][:value]

      expect(sql.grep(/\A(ALTER|CREATE)/)).to be_empty
      expect(report).to include("already: role hecks_qa exists, ordinary")
                    .and include("already: database ledger already owned by hecks_qa")
      expect(report).not_to include("bind it")
    end

    it "refuses a role the era write-fence cannot bind" do
      answers["FROM pg_roles"] = [{ "rolsuper" => "t", "rolbypassrls" => "f" }]

      expect { admin.create_ledger_role(database: "ledger") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /superuser.*write-fence/)
      expect(sql.grep(/ALTER/)).to be_empty
    end

    it "refuses a database that does not exist, and never creates it" do
      answers["FROM pg_database"] = []

      expect { admin.create_ledger_role(database: "nope") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no database nope: createdb it first/)
      expect(sql.grep(/CREATE DATABASE/)).to be_empty
    end

    it "refuses when no database is named" do
      expect { admin.create_ledger_role(database: "") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no database named/)
    end

    it "answers a server error as a refusal with its reason" do
      described_class.connector = ->(dbname:) { raise IOError, "connection refused" }

      expect { admin.create_ledger_role(database: "ledger") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /postgres: connection refused/)
    end
  end

  describe "#create_database" do
    it "creates a database that is not there" do
      report = admin.create_database(database: "scratch_1")[:report][:value]

      expect(sql).to include('CREATE DATABASE "scratch_1"')
      expect(report).to eq("created database scratch_1")
    end

    it "reports one that exists instead of creating it again" do
      answers["FROM pg_database"] = [{ "?column?" => "1" }]

      expect(admin.create_database(database: "scratch_1")[:report][:value]).to eq("database scratch_1 already exists")
      expect(sql.grep(/CREATE DATABASE/)).to be_empty
    end
  end

  describe "#drop_database" do
    it "ends other sessions, then drops" do
      answers["FROM pg_database"] = [{ "?column?" => "1" }]

      report = admin.drop_database(database: "scratch_1")[:report][:value]

      expect(sql.index { |line| line.include?("pg_terminate_backend") }).to be < sql.index('DROP DATABASE "scratch_1"')
      expect(report).to eq("dropped database scratch_1")
    end

    it "refuses a name that is not a scratch database, before connecting" do
      %w[hecks_ledger production scratch scratch_ postgres template1 scratch-1].each do |name|
        expect { admin.drop_database(database: name) }
          .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /refusing to drop #{name}/)
      end
      expect(sql).to be_empty
    end

    it "refuses the ledger or production database the environment names, even under a scratch name" do
      { "PGDATABASE" => "scratch_live", "HECKS_LEDGER_DATABASE" => "scratch_ledger",
        "DATABASE_URL" => "postgres://u:p@host:5432/scratch_prod" }.each do |variable, value|
        stub_const("ENV", ENV.to_h.merge(variable => value))
        name = value.split("/").last

        expect { admin.drop_database(database: name) }
          .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /ledger, production or a system database/)
      end
      expect(sql).to be_empty
    end

    it "says so when there is nothing to drop" do
      expect(admin.drop_database(database: "scratch_gone")[:report][:value]).to eq("no database scratch_gone")
      expect(sql.grep(/DROP/)).to be_empty
    end
  end

  it "closes every connection it opens, even when a step raises" do
    connections = []
    described_class.connector = lambda do |dbname:|
      FakePgConnection.new(dbname, { "FROM pg_database" => [] }, log).tap { |connection| connections << connection }
    end

    expect { admin.create_ledger_role(database: "nope") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
    expect(connections).to all(have_attributes(closed: true))
  end
end

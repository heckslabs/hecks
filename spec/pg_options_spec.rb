require "spec_helper"
require "hecks/pg_options"

# Every Postgres connection of the process carries `gssencmode=disable` unless its caller chose a
# value, so libpq never asks the macOS Kerberos framework for a credential cache (a forked
# resident child crashed there). Nothing here talks to a database: a connection is only started
# against a refused port, or its connection string is read.
RSpec.describe Hecks::PgOptions do
  def option(conninfo)
    PG::Connection.conninfo_parse(conninfo).find { |entry| entry[:keyword] == "gssencmode" }&.fetch(:val)
  end

  def parsed(*args) = option(PG::Connection.parse_connect_args(*args))

  def started(conninfo)
    connection = PG::Connection.connect_start(conninfo)
    connection.conninfo_hash[:gssencmode]
  ensure
    connection&.finish
  end

  it "is installed on the pg gem's connection class methods" do
    expect(PG::Connection.singleton_class.include?(described_class::Connecting)).to be(true)
  end

  it "installs once, however often it is asked" do
    2.times { described_class.install! }
    expect(PG::Connection.singleton_class.ancestors.count(described_class::Connecting)).to eq(1)
  end

  it "adds the option to a hash, a keyword string, a URL and positional values", :aggregate_failures do
    expect(parsed(dbname: "x")).to eq("disable")
    expect(parsed("dbname=x port=5432")).to eq("disable")
    expect(parsed("postgresql://u@h/db")).to eq("disable")
    expect(parsed("localhost", 5432, nil, nil, "db")).to eq("disable")
  end

  it "adds it to a connection made with no arguments" do
    expect(parsed).to eq("disable")
  end

  it "keeps a value the caller named", :aggregate_failures do
    expect(parsed(dbname: "x", gssencmode: "prefer")).to eq("prefer")
    expect(parsed("dbname=x gssencmode=require")).to eq("require")
    expect(parsed("postgresql://u@h/db?gssencmode=prefer")).to eq("prefer")
    expect(parsed({ "gssencmode" => "prefer" })).to eq("prefer")
  end

  it "adds it to a connection started from a string, a URL or a hash", :aggregate_failures do
    refused = "host=127.0.0.1 port=1 connect_timeout=1"
    expect(started(refused)).to eq("disable")
    expect(started("postgresql://u@127.0.0.1:1/db?connect_timeout=1")).to eq("disable")
    expect(started(host: "127.0.0.1", port: 1, connect_timeout: 1)).to eq("disable")
    expect(started("#{refused} gssencmode=prefer")).to eq("prefer")
  end

  it "leaves the arguments it was given alone" do
    given = ["dbname=x", { connect_timeout: 2 }].freeze
    expect { described_class.arguments(given) }.not_to(change { given.map(&:dup) })
  end

  it "does not install on a libpq older than the keyword" do
    allow(PG).to receive(:library_version).and_return(described_class::MINIMUM_LIBPQ - 1)
    expect(described_class.install!).to be_nil
  end

  it "is the only place lib requires pg, so a new connection site cannot skip it" do
    root = File.expand_path("../lib", __dir__)
    bare = Dir.glob(File.join(root, "**", "*.rb")).grep_v(%r{/hecks/pg_options\.rb\z}).select do |file|
      File.foreach(file).any? { |line| line.strip == 'require "pg"' }
    end
    expect(bare).to eq([])
  end
end

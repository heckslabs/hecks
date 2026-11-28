require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/settings_reading"
require_relative "../../support/registry_double"

# `hecks config` shows the store each bluebook resolves to, and the aggregate binds that
# override it.
RSpec.describe Hecks::Adapters::SettingsReading do
  include RegistryDouble

  let(:binds) { [] }

  def reading = described_class.new

  def directory = @directory ||= Dir.mktmpdir("settings-stores")

  def shop = Struct.new(:name, :aggregates).new("Shop", [Struct.new(:name, :hecks_name).new("Order", "Order")])

  def hecksagon = instance_double(Hecks::Bluebook::Hecksagon, binds: binds, default_binds: [])

  def registry(default_adapter: nil, database: nil)
    registry_double(bluebooks: { "Shop" => shop }, hecksagon: hecksagon, default_adapter_for: default_adapter,
                    default_database_for: database, first_domain_name: "Shop")
  end

  def stores(text) = text.lines.map(&:chomp).select { |line| line.start_with?("store ") }

  def read(registry)
    allow(Hecks).to receive(:describe).with(directory).and_return(instance_double(Hecks::Runtime::Loader::Described,
                                                                                  registry: registry))
    reading.settings(domain: { value: directory }).fetch(:text)
  end

  before do
    allow(Hecks::Ports::Persistence::BindingPolicy).to receive_messages(
      inherited_adapter: nil,
      resolve:           Hecks::Bluebook::Bind.new(aggregate: "Order", verb: "persisted_by", adapter: "Memory")
    )
  end

  after { FileUtils.remove_entry(directory) if @directory }

  it "shows a bluebook with no binding as Memory from the default" do
    expect(stores(read(registry))).to eq(["store Shop: Memory (default)"])
  end

  context "when the hecksagon binds one aggregate to SQLite" do
    let(:binds) { [Hecks::Bluebook::Bind.new(aggregate: "Shop::Order", verb: "persisted_by", adapter: "SqlitePersistence")] }

    it "shows the aggregate's own store, marked as an aggregate bind" do
      allow(Hecks::Ports::Persistence::BindingPolicy).to receive(:resolve).and_return(binds.first)
      reg = registry
      allow(reg).to receive(:binding_settings).with("Shop", "persisted_by", "SqlitePersistence")
                                              .and_return({ database: "/tmp/orders.db" })

      expect(stores(read(reg))).to include("store Shop::Order: SqliteAt /tmp/orders.db (aggregate bind in the hecksagon)")
    end
  end

  context "when the world names a Postgres database with a password" do
    let(:reg) { registry(default_adapter: "Postgres", database: url) }
    let(:url) { "postgres://hecks:secret@localhost/hecks_train" }

    before { allow(reg).to receive(:binding_settings).with("Shop", "persisted_by", "Postgres").and_return({ database: url }) }

    it "names the database without its password" do
      expect(stores(read(reg))).to eq(["store Shop: Postgres hecks_train (world default_adapter)"])
    end

    it "never prints the password" do
      expect(read(reg)).not_to include("secret")
    end
  end
end

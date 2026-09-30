# frozen_string_literal: true

require "json"
require "hecks"
require "fileutils"

module Hecks
  # The seed records of `spec/fixtures/persistence_legacy/`, over `examples/banking`, and the
  # regeneration of those fixtures through the real adapters.
  #
  # Banking's IR only: no hecksagon, no boot; adapters are built straight from `aggregate:`.
  module PersistenceLegacyFixture
    # The gem's root directory.
    ROOT = File.expand_path("../..", __dir__)
    # Where the fixtures stand in a checkout.
    DIR  = File.join(ROOT, "spec/fixtures/persistence_legacy").freeze

    # Each seed: aggregate name, id and field values.
    SEEDS = [
      [
        "Account", "ACC-1",
        {
          number:          { value: "ACC-1" },
          customer:        "CUST-1",
          balance:         { cents: 1250, currency: "USD" },
          kind:            { name: "current" },
          daily_limit:     { cents: 500 },
          ledger:          [
            { sequence: { value: 1 }, amount: { cents: 1000, currency: "USD" }, narrative: { text: "opening" },
              direction: { value: "credit" }, state: "posted" },
            { sequence: { value: 2 }, amount: { cents: 250, currency: "USD" }, narrative: { text: "top up" },
              direction: { value: "credit" }, state: "reversed" }
          ],
          status:          "open",
          customer_status: "active"
        }
      ],
      [
        "CardPayment", "AUTH-1",
        {
          authorisation:  { value: "AUTH-1" },
          account:        "ACC-1",
          amount:         { cents: 300 },
          merchant:       { value: "Cafe" },
          tags:           [{ value: "food" }, { value: "travel" }],
          status:         "authorized",
          account_status: "open"
        }
      ]
    ].freeze

    module_function

    # @return [Hecks::Bluebook::Structure::Domain] banking's bluebook, loaded once
    def bluebook
      @bluebook ||= begin
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(File.join(ROOT, "lib/hecks/ports/persistence.port"))
          Kernel.load(File.join(ROOT, "lib/hecks/ports/extraction.port"))
          Kernel.load(File.join(ROOT, "lib/hecks/adapters/driven/prism.adapter"))
          folder = Hecks::Adapters::Folder.new
          folder.load_bluebooks(folder.bluebook_directory(File.join(ROOT, "examples/banking/bluebook")))
        end
        registry.bluebook("Banking")
      end
    end

    # @param name [String] an aggregate of banking
    # @return [Object] its definition
    def aggregate(name) = bluebook.aggregate(name)

    # @return [Array<Hecks::Runtime::Instance>] one instance for each seed
    def instances
      SEEDS.map do |name, id, fields|
        aggregate = aggregate(name)
        instance = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
        fields.each { |field, value| instance[field] = Hecks::Runtime::Value.for(aggregate, field, value) }
        instance
      end
    end

    # In-memory SQLite answering `Connection`'s four methods, as `d1_spec.rb` does.
    #
    # @return [Object] the connection
    def fake_d1_connection
      require "sqlite3"
      db = SQLite3::Database.new(":memory:")
      db.results_as_hash = true
      Class.new do
        def initialize(db) = @db = db
        def execute(sql, binds = []) = @db.execute(sql, binds)
        def get_first_row(sql, binds = []) = execute(sql, binds).first
        def get_first_value(sql, binds = []) = get_first_row(sql, binds)&.values&.first
      end.new(db)
    end

    # Makes `D1::Connection.new` answer `connection` for the length of the block.
    #
    # @param connection [Object] the connection to answer
    # @yield the work that builds a D1 adapter
    # @return [Object] the block's value
    def with_d1_connection(connection)
      klass = Hecks::Adapters::D1::Connection
      klass.define_singleton_method(:new) { |**| connection }
      yield
    ensure
      klass.singleton_class.send(:remove_method, :new) if klass.singleton_class.method_defined?(:new, false)
    end
  end
end

require_relative "persistence_legacy_fixture/regenerate"

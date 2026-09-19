require "spec_helper"
require "tmpdir"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/persistence_legacy_fixture"
require_relative "../support/postgres_probe"

# One round-trip contract, every persistence adapter (Phase 2, Track A,
# PR A3). Since A3 every adapter writes through
# `Ports::Persistence::StateCodec.encode` and reads through `decode`, so
# they must all agree on exactly what a saved record reads back as —
# head and journal alike. The examples below are shared, verbatim, by
# Memory, Heki, Sqlite, D1 (over a real in-memory SQLite, the stand-in
# spec/adapters/driven/d1_spec.rb uses), Postgres and PostgresEra.
#
# The shapes, from `examples/banking` (PersistenceLegacyFixture::SEEDS):
# Account — nested multi-field value objects (Money), a list of entities
# each holding its own nested value objects plus its own lifecycle field
# (`ledger`), a reference (`customer`), the lifecycle field (`status`), a
# seeded projected field (`customer_status`). CardPayment — a list of
# value objects (`tags`), a required and a nil optional reference, and a
# never-seeded projected field (`account_customer_status`).
#
# Every adapter here is guarded exactly as `RepositoryFactory.build`
# guards it (`CodecBoundary.guard!`) and driven through `AppendOnly`, so a
# contract pass also proves no adapter builds an `Instance` from state the
# codec has not decoded.
RSpec.describe "persistence adapter contract (state codec round trip)" do
  def fixture = PersistenceLegacyFixture

  def canonical(name)
    {
      "Account"     => {
        customer:        "CUST-1",
        number:          { value: "ACC-1" },
        balance:         { cents: 1250, currency: "USD" },
        kind:            { name: "current" },
        daily_limit:     { cents: 500 },
        ledger:          [
          { sequence: { value: 1 }, amount: { cents: 1000, currency: "USD" }, narrative: { text: "opening" },
            direction: { value: "credit" }, state: "posted" },
          { sequence: { value: 2 }, amount: { cents: 250, currency: "USD" }, narrative: { text: "top up" },
            direction: { value: "credit" }, state: "reversed" }
        ],
        fees_cents:      { cents: 0, currency: "USD" },
        interest_cents:  { cents: 0, currency: "USD" },
        status:          "open",
        customer_status: "active"
      },
      "CardPayment" => {
        account:        "ACC-1",
        disputed_by:    nil,
        authorisation:  { value: "AUTH-1" },
        amount:         { cents: 300 },
        merchant:       { value: "Cafe" },
        tags:           [{ value: "food" }, { value: "travel" }],
        status:         "authorized",
        account_status: "open"
      }
    }.fetch(name)
  end

  def live(name) = fixture.instances.find { |instance| instance.aggregate.name == name }

  # The raw `state:` the last `Instance.new` inside the block was handed.
  def decoded_state
    captured = []
    allow(Hecks::Runtime::Instance).to receive(:new).and_wrap_original do |original, **kwargs|
      captured << kwargs[:state]
      original.call(**kwargs)
    end
    yield
    captured.last
  end

  def repository_for(aggregate)
    adapter = Hecks::Ports::Persistence::CodecBoundary.guard!(build_adapter(aggregate))
    Hecks::Ports::Persistence::AppendOnly.new(adapter)
  end

  shared_examples "a state-codec persistence adapter" do |durable:|
    %w[Account CardPayment].each do |name|
      context "with #{name}" do
        let(:aggregate) { fixture.aggregate(name) }
        let(:record) { live(name) }
        let(:repository) { repository_for(aggregate) }

        # The save goes inside the capture: Memory builds its record's
        # Instance when it projects, not when it is read, so the last
        # construction is the projected copy there and the read's decode
        # everywhere else.
        def read_after_save(&read)
          decoded_state do
            repository.save(record)
            read.call
          end
        end

        it "reads a saved record back from find in the one canonical, deep-symbol shape" do
          expect(read_after_save { repository.find(record.id) }).to eq(canonical(name))
        end

        it "reads it back identically from all" do
          expect(read_after_save { repository.all }).to eq(canonical(name))
        end

        it "hydrates into the same record that was saved" do
          repository.save(record)

          expect(Hecks::Runtime::Value.materialize(repository.find(record.id).to_h))
            .to eq(Hecks::Runtime::Value.materialize(record.to_h))
        end

        it "journals the same canonical state it projects" do
          repository.save(record)

          expect(repository.entries.map(&:state)).to eq([canonical(name)])
        end

        it "leaves a never-seeded projected field absent, and keeps a stored nil reference as nil" do
          state = read_after_save { repository.find(record.id) }

          aggregate.projected_fields.each do |field|
            expect(state.key?(field.name)).to eq(record.key?(field.name)), "#{field.name} presence"
          end
          expect(state).to include(disputed_by: nil) if name == "CardPayment"
        end

        it "forgets a deleted record" do
          repository.save(record)
          repository.delete(record.id)

          expect(repository.find(record.id)).to be_nil
          expect(repository.count).to eq(0)
        end

        if durable
          it "reads the same canonical state from a second adapter over the same store (recover! included)" do
            repository.save(record)
            reopened = repository_for(aggregate).recover!

            expect(decoded_state { reopened.find(record.id) }).to eq(canonical(name))
            expect(reopened.entries.map(&:state)).to eq([canonical(name)])
          end
        end
      end
    end
  end

  around do |example|
    @dir = Dir.mktmpdir("hecks-persistence-contract-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  describe Hecks::Adapters::Memory do
    def build_adapter(aggregate) = Hecks::Adapters::Memory.new(aggregate: aggregate)

    it_behaves_like "a state-codec persistence adapter", durable: false
  end

  describe Hecks::Adapters::Heki do
    def build_adapter(aggregate) = Hecks::Adapters::Heki.new(aggregate: aggregate, settings: { dir: "." }, root: @dir)

    it_behaves_like "a state-codec persistence adapter", durable: true
  end

  describe Hecks::Adapters::Sqlite do
    def build_adapter(aggregate)
      Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "contract.sqlite3" }, root: @dir)
    end

    it_behaves_like "a state-codec persistence adapter", durable: true
  end

  describe Hecks::Adapters::D1 do
    # One in-memory SQLite per example, shared by every adapter the example
    # builds — so a "second adapter over the same store" really is one.
    def connection = (@connection ||= fixture.fake_d1_connection)

    def build_adapter(aggregate)
      fixture.with_d1_connection(connection) do
        Hecks::Adapters::D1.new(aggregate: aggregate, settings: { account_id: "acc", database_id: "db", api_token: "tok" })
      end
    end

    it_behaves_like "a state-codec persistence adapter", durable: true
  end

  context "with a real Postgres", :io do
    def databases = { postgres: "hecks_persistence_contract_spec", postgres_era: "hecks_persistence_contract_era_spec" }

    before(:all) do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      admin = PG.connect(dbname: "postgres")
      databases.each_value do |name|
        admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
        admin.exec("CREATE DATABASE #{name}")
      end
      admin.close
    end

    after(:all) do
      next unless PostgresProbe.available?

      admin = PG.connect(dbname: "postgres")
      databases.each_value { |name| admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)") }
      admin.close
    end

    before do
      databases.each_value do |name|
        scrub = PG.connect(dbname: name)
        scrub.exec("DROP SCHEMA public CASCADE")
        scrub.exec("CREATE SCHEMA public")
        scrub.close
      end
    end

    describe Hecks::Adapters::Postgres do
      def build_adapter(aggregate)
        Hecks::Adapters::Postgres.new(aggregate: aggregate, settings: { database: databases[:postgres] })
      end

      it_behaves_like "a state-codec persistence adapter", durable: true
    end

    describe Hecks::Adapters::PostgresEra do
      def build_adapter(aggregate)
        Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: databases[:postgres_era] })
      end

      it_behaves_like "a state-codec persistence adapter", durable: true
    end
  end

  # ── the enforcement: RepositoryFactory.build guards every adapter ─────

  describe "RepositoryFactory.build's codec boundary" do
    let(:aggregate) { fixture.aggregate("Account") }

    # An adapter that "forgets" the codec: symbolizes one level by hand, the
    # way Heki and every journal reader used to.
    let(:forgetful_class) do
      Class.new(Hecks::Adapters::Memory) do
        def find(id)
          Hecks::Runtime::Instance.new(aggregate: @aggregate, id: id,
                                       state: { status: "open", balance: { "cents" => 1, "currency" => "USD" } })
        end

        def entries = [Hecks::Ports::Persistence::Entry.new(operation: "save", id: "A", state: { "status" => "open" })]
      end
    end

    let(:registry) do
      adapter_class = forgetful_class
      instance_double(Hecks::Runtime::Registry, root: nil, resolved_eras: {}, superseded_eras: {}).tap do |double|
        allow(double).to receive_messages(check_verb: nil, world: nil, check_settings: nil, adapter_class: adapter_class)
      end
    end

    let(:bind) { Hecks::Bluebook::Bind.new(aggregate: "Account", verb: "persisted_by", adapter: "Forgetful") }

    def build(recover: false)
      Hecks::Ports::Persistence::RepositoryFactory.build(registry, "Banking", aggregate, bind, recover: recover)
    end

    it "refuses an Instance an adapter builds from undecoded state, naming the codec" do
      expect { build.find("A") }.to raise_error(Hecks::Runtime::WiringError, /undecoded state.*StateCodec\.decode/)
    end

    it "refuses it even when reached through repository.adapter, not the repository" do
      expect { build.adapter.find("A") }.to raise_error(Hecks::Runtime::WiringError, /undecoded state/)
    end

    it "refuses undecoded journal entries — so recovery never replays them" do
      expect { build(recover: true) }.to raise_error(Hecks::Runtime::WiringError, /journal entry "A" with undecoded state/)
    end

    it "keeps the adapter's own identity, and leaves a caller's block (the dispatch itself) outside the boundary" do
      repository = build

      expect(repository.adapter).to be_a(forgetful_class)
      expect do
        repository.transaction do
          Hecks::Runtime::Instance.new(aggregate: aggregate, id: "A", state: undecoded_nested)
        end
      end.not_to raise_error
    end

    # Nested string keys under a declared value object: undecoded to the
    # boundary, still accepted by hydration's own input door. A string
    # top-level key is refused everywhere since A4 (Value.hydrate).
    def undecoded_nested = { status: "open", balance: { "cents" => 1, "currency" => "USD" } }

    it "does nothing to an Instance built outside any adapter call" do
      expect { Hecks::Runtime::Instance.new(aggregate: aggregate, id: "A", state: undecoded_nested) }.not_to raise_error
    end

    it "refuses a string top-level key at hydration, inside or outside any adapter call" do
      expect { Hecks::Runtime::Instance.new(aggregate: aggregate, id: "A", state: { "status" => "open" }) }
        .to raise_error(Hecks::Runtime::WiringError, /non-Symbol keys \["status"\].*StateCodec\.decode/)
    end
  end
end

require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"

# `spec/runtime/outbox_spec.rb`'s crash cases, against the two Postgres
# adapters — the enqueue shares the save's transaction (`Adapters::
# PostgresOutbox#transaction` joins an open one instead of nesting a
# BEGIN), a pending row survives a crash and is redriven on the next
# boot, a claimed row is surfaced and left alone.
RSpec.describe "the transactional outbox, against Postgres", :io do
  OUTBOX_SPEC_DB = "hecks_outbox_spec".freeze

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{OUTBOX_SPEC_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{OUTBOX_SPEC_DB}")
    admin.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{OUTBOX_SPEC_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: OUTBOX_SPEC_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  def boot_shop(adapter) # rubocop:disable Metrics/MethodLength
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::POSTGRES_ADAPTER)
      Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)

      Hecks.bluebook "Shop" do
        vision "An order placed is an order remembered."
        core

        aggregate "Order" do
          value_object("Number") { attribute :value, String }
          attribute :number, Number
          identified_by :number

          command "Place" do
            attribute :number, Number
            sets :number
            emits "OrderPlaced"
          end
        end

        aggregate "Ledger" do
          value_object("Number") { attribute :value, String }
          attribute :number, Number
          identified_by :number

          command "Record" do
            attribute :number, Number
            sets :number
            emits "OrderRecorded"
          end
        end

        policy "RecordOrder" do
          on "OrderPlaced"
          trigger Ledger::Record, with: { number: :number }
        end
      end

      Hecks.hecksagon("Shop") { persisted_by adapter }
      Hecks.world("Shop") { persisted_by(adapter) { database(OUTBOX_SPEC_DB) } }
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def place(runtime, number)
    runtime.dispatch("Shop::Order.Place", with: { number: { value: number } })
  end

  def ledger(runtime, number)
    runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Ledger")).find(number)
  end

  def order_repository(runtime)
    runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Order"))
  end

  %w[Postgres PostgresEra].each do |adapter|
    describe adapter do
      it "delivers inline and records the row" do
        runtime = boot_shop(adapter)
        place(runtime, "o-1")

        expect(runtime.outbox.rows.map { |row| [row.consumer, row.status, row.attempts] })
          .to eq([["policy:Shop::RecordOrder", "delivered", 1]])
        expect(ledger(runtime, "o-1")).not_to be_nil
      end

      it "rolls the save back with the outbox row when the emit fails" do
        runtime = boot_shop(adapter)
        repository = order_repository(runtime)
        allow(repository.adapter).to receive(:record_event).and_raise(RuntimeError, "disk full")

        expect { place(runtime, "o-1") }.to raise_error(RuntimeError, "disk full")
        expect(repository.find("o-1")).to be_nil
        expect(runtime.outbox.rows).to be_empty
      end

      it "redrives a pending row on the next boot" do
        runtime = boot_shop(adapter)
        allow(runtime.outbox).to receive(:deliver).and_raise(Interrupt)
        expect { place(runtime, "o-1") }.to raise_error(Interrupt)
        expect(runtime.outbox.rows.map(&:status)).to eq(["pending"])

        rebooted = boot_shop(adapter)
        expect(rebooted.outbox.redrive!.size).to eq(1)
        expect(rebooted.outbox.rows.map(&:status)).to eq(["delivered"])
        expect(ledger(rebooted, "o-1")).not_to be_nil
      end

      it "surfaces a claimed row and redrives it only on request" do
        runtime = boot_shop(adapter)
        allow(runtime.instance_variable_get(:@policies)).to receive(:react).and_raise(Interrupt)
        expect { place(runtime, "o-1") }.to raise_error(Interrupt)
        expect(runtime.outbox.rows.map(&:status)).to eq(["claimed"])

        rebooted = boot_shop(adapter)
        expect { expect(rebooted.outbox.redrive!).to be_empty }.to output(/claimed before the last crash/).to_stderr
        expect(ledger(rebooted, "o-1")).to be_nil

        expect(rebooted.outbox.redrive!(claimed: true).size).to eq(1)
        expect(rebooted.outbox.rows.first).to have_attributes(status: "delivered", attempts: 2)
        expect(ledger(rebooted, "o-1")).not_to be_nil
      end
    end
  end
end

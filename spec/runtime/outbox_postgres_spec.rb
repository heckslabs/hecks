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

  OUTBOX_PG_SHOP_DOMAIN = proc do
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

  def load_postgres_stack
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    Kernel.load(InMemoryDomain::POSTGRES_ADAPTER)
    Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER)
  end

  def boot_shop(adapter)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      load_postgres_stack
      Hecks.bluebook("Shop", &OUTBOX_PG_SHOP_DOMAIN)
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
      let(:runtime) { boot_shop(adapter) }
      let(:rebooted) { boot_shop(adapter) }

      # A crash is not a StandardError, so nothing in the pipeline rescues it; stubbing
      # `message` on the target to raise Interrupt simulates the process vanishing mid-dispatch.
      def crash_placing(target, message)
        allow(target).to receive(message).and_raise(Interrupt)
        expect { place(runtime, "o-1") }.to raise_error(Interrupt)
      end

      it "delivers inline and records the row", :aggregate_failures do
        place(runtime, "o-1")

        expect(runtime.outbox.rows.map { |row| [row.consumer, row.status, row.attempts] })
          .to eq([["policy:Shop::RecordOrder", "delivered", 1]])
        expect(ledger(runtime, "o-1")).not_to be_nil
      end

      it "rolls the save back with the outbox row when the emit fails", :aggregate_failures do
        repository = order_repository(runtime)
        allow(repository.adapter).to receive(:record_event).and_raise(RuntimeError, "disk full")

        expect { place(runtime, "o-1") }.to raise_error(RuntimeError, "disk full")
        expect([repository.find("o-1"), runtime.outbox.rows]).to eq([nil, []])
      end

      it "keeps a pending row across a crash between commit and reaction" do
        crash_placing(runtime.outbox, :deliver)

        expect(runtime.outbox.rows.map(&:status)).to eq(["pending"])
      end

      it "redrives a pending row on the next boot", :aggregate_failures do
        crash_placing(runtime.outbox, :deliver)

        expect(rebooted.outbox.redrive!.size).to eq(1)
        expect(rebooted.outbox.rows.map(&:status)).to eq(["delivered"])
        expect(ledger(rebooted, "o-1")).not_to be_nil
      end

      it "leaves a claimed row behind when the crash comes after the claim" do
        crash_placing(runtime.instance_variable_get(:@policies), :react)

        expect(runtime.outbox.rows.map(&:status)).to eq(["claimed"])
      end

      it "surfaces a claimed row instead of redriving it", :aggregate_failures do
        crash_placing(runtime.instance_variable_get(:@policies), :react)

        expect { expect(rebooted.outbox.redrive!).to be_empty }.to output(/claimed before the last crash/).to_stderr
        expect(ledger(rebooted, "o-1")).to be_nil
      end

      it "redrives a claimed row only on request", :aggregate_failures do
        crash_placing(runtime.instance_variable_get(:@policies), :react)

        expect(rebooted.outbox.redrive!(claimed: true).size).to eq(1)
        expect(rebooted.outbox.rows.first).to have_attributes(status: "delivered", attempts: 2)
        expect(ledger(rebooted, "o-1")).not_to be_nil
      end
    end
  end
end

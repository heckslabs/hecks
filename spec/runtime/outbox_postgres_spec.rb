require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"
require_relative "../support/scratch_postgres"

# `spec/runtime/outbox_spec.rb`'s crash cases, against the two Postgres
# adapters — the enqueue shares the save's transaction (`Adapters::
# PostgresOutbox#transaction` joins an open one instead of nesting a
# BEGIN), a pending row survives a crash and is redriven on the next
# boot, a claimed row is surfaced and left alone.
RSpec.describe "the transactional outbox, against Postgres", :io do
  OUTBOX_SPEC_DB = "hecks_outbox_spec".freeze

  scratch_postgres OUTBOX_SPEC_DB

  OUTBOX_PG_SHOP_DOMAIN = proc do
    vision "An order placed is an order remembered."
    core

    aggregate "Order" do
      value_object "Number", String
      attribute :number, Number
      identified_by :number

      command "Place" do
        attribute :number, Number
        sets :number
        emits "OrderPlaced"
      end
    end

    aggregate "Ledger" do
      value_object "Number", String
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
    MemoryPorts.load!
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

      # Moves every claim back in time, so a claim made a moment ago stands as old as `seconds`,
      # as one left by a process that has long gone would.
      def claimed_ago(seconds)
        db = PG.connect(dbname: OUTBOX_SPEC_DB)
        db.exec_params("UPDATE hecks_outbox SET claimed_at = now() - make_interval(secs => $1) " \
                       "WHERE status = 'claimed'", [seconds])
      ensure
        db&.close
      end

      def crash_leaving_stalled_claim
        crash_placing(runtime.instance_variable_get(:@policies), :react)
        claimed_ago(Hecks::Runtime::Outbox::STALLED_AFTER + 60)
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
        crash_leaving_stalled_claim

        expect { expect(rebooted.outbox.redrive!).to be_empty }.to output(/claimed before the last crash/).to_stderr
        expect(ledger(rebooted, "o-1")).to be_nil
      end

      it "redrives a claimed row only on request", :aggregate_failures do
        crash_leaving_stalled_claim

        expect(rebooted.outbox.redrive!(claimed: true).size).to eq(1)
        expect(rebooted.outbox.rows.first).to have_attributes(status: "delivered", attempts: 2)
        expect(ledger(rebooted, "o-1")).not_to be_nil
      end

      it "leaves a row claimed a moment ago alone, as a reaction still running", :aggregate_failures do
        crash_placing(runtime.instance_variable_get(:@policies), :react)

        expect { expect(rebooted.outbox.redrive!(claimed: true)).to be_empty }.not_to output.to_stderr
        expect(rebooted.outbox.rows.first).to have_attributes(status: "claimed", claimed_for: be < 60)
      end
    end
  end
end

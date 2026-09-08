require "spec_helper"
require "tmpdir"

# THE TRANSACTIONAL OUTBOX (`Runtime::Outbox`) — a command's save, its
# events, and one row per (event, consumer) commit together; the
# dispatcher then drains those rows inline (pending → claimed →
# delivered | failed); a row left behind by a crash is found again on
# the next boot. `future-features.md` item 8.
RSpec.describe "the transactional outbox" do
  SQLITE_ADAPTER_FILE = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")

  # Two aggregates, one policy between them: placing an Order owes the
  # Ledger a Record. The policy is the outbox's consumer; the Ledger row
  # is the proof it ran.
  def declare_shop(registry)
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(SQLITE_ADAPTER_FILE)

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

          command "Touch" do
            reference_to Order
            emits "OrderTouched"
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
    end
  end

  def boot_memory
    registry = Hecks::Runtime::Registry.new
    declare_shop(registry)
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def boot_sqlite(dir)
    registry = Hecks::Runtime::Registry.new
    declare_shop(registry)
    Hecks.with_registry(registry) do
      Hecks.hecksagon("Shop") { persisted_by "SqlitePersistence" }
      Hecks.world("Shop") { persisted_by("SqlitePersistence") { database(File.join(dir, "shop.db")) } }
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

  describe "on Memory" do
    it "records one delivered row per (event, consumer) and runs the consumer inline" do
      runtime = boot_memory
      place(runtime, "o-1")

      rows = runtime.outbox.rows
      expect(rows.map(&:consumer)).to eq(["policy:Shop::RecordOrder"])
      row = rows.first
      expect(row).to be_delivered
      expect(row.kind).to eq("reaction")
      expect(row.attempts).to eq(1)
      expect(row.event[:name]).to eq("OrderPlaced")
      expect(row.delivery_id).to eq("#{row.event_uid}/policy:Shop::RecordOrder")
      expect(ledger(runtime, "o-1")).not_to be_nil
      expect(runtime.reactions.last).to include(policy: "RecordOrder", delivered: true)
    end

    it "writes no row for an event nothing listens to" do
      runtime = boot_memory
      place(runtime, "o-1")
      runtime.dispatch("Shop::Order.Touch", to: "o-1")

      expect(runtime.outbox.rows.map { |row| row.event[:name] }).to eq(["OrderPlaced"])
    end

    it "treats a re-enqueue of the same fact to the same consumer as a no-op" do
      runtime = boot_memory
      place(runtime, "o-1")
      repository = runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Order"))
      held = runtime.outbox.rows.first

      duplicate = Hecks::Runtime::Outbox::Row.new(held.to_h.merge(id: nil, status: "pending", attempts: 0))
      expect(repository.outbox_enqueue([duplicate])).to eq([])
      expect(runtime.outbox.rows.size).to eq(1)
    end

    it "marks a row failed, with the defect, when its consumer cannot run at all" do
      runtime = boot_memory
      place(runtime, "o-1")
      repository = runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Order"))
      held = runtime.outbox.rows.first

      orphan = Hecks::Runtime::Outbox::Row.new(
        held.to_h.merge(id: nil, status: "pending", attempts: 0,
                        consumer: "policy:Shop::Vanished", delivery_id: "#{held.event_uid}/policy:Shop::Vanished")
      )
      stored, = repository.outbox_enqueue([orphan])
      expect(runtime.outbox.deliver_row(stored, repository)).to be(false)

      row = runtime.outbox.rows(status: "failed").first
      expect(row.consumer).to eq("policy:Shop::Vanished")
      expect(row.error).to match(/WiringError.*Vanished/)
      expect(runtime.outbox.log.last).to include(outbox: row.delivery_id, defect: true)
    end

    it "does not enqueue for a dry run, which commits nothing" do
      runtime = boot_memory
      expect(runtime.dry_run?("Shop::Order.Place", number: { value: "o-9" })).to be(true)
      expect(runtime.outbox.rows).to be_empty
    end
  end

  describe "on SqlitePersistence" do
    it "commits the save, the event, and the outbox rows as one transaction" do
      Dir.mktmpdir do |dir|
        runtime = boot_sqlite(dir)
        repository = runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Order"))

        allow(repository.adapter).to receive(:record_event).and_raise(RuntimeError, "disk full")

        expect { place(runtime, "o-1") }.to raise_error(RuntimeError, "disk full")
        expect(repository.find("o-1")).to be_nil
        expect(repository.entries).to be_empty
        expect(runtime.outbox.rows).to be_empty
      end
    end

    it "keeps a pending row across a crash between commit and reaction, and redrives it on the next boot" do
      Dir.mktmpdir do |dir|
        runtime = boot_sqlite(dir)
        # A crash is not a StandardError — nothing in the pipeline
        # rescues it, the process is simply gone. Killing the relay's
        # deliver before it claims anything leaves the row `pending`.
        allow(runtime.outbox).to receive(:deliver).and_raise(Interrupt)
        expect { place(runtime, "o-1") }.to raise_error(Interrupt)

        expect(runtime.outbox.rows.map(&:status)).to eq(["pending"])
        expect(ledger(runtime, "o-1")).to be_nil

        rebooted = boot_sqlite(dir)
        expect(ledger(rebooted, "o-1")).to be_nil

        redriven = rebooted.outbox.redrive!
        expect(redriven.map(&:consumer)).to eq(["policy:Shop::RecordOrder"])
        expect(rebooted.outbox.rows.map(&:status)).to eq(["delivered"])
        expect(ledger(rebooted, "o-1")).not_to be_nil
        expect(rebooted.reactions.last).to include(policy: "RecordOrder", delivered: true)
      end
    end

    it "surfaces a claimed row instead of redriving it, until told the redrive is safe" do
      Dir.mktmpdir do |dir|
        runtime = boot_sqlite(dir)
        policies = runtime.instance_variable_get(:@policies)
        # Crash AFTER the claim, INSIDE the consumer — the outcome is
        # genuinely unknown to the next boot.
        allow(policies).to receive(:react).and_raise(Interrupt)
        expect { place(runtime, "o-1") }.to raise_error(Interrupt)
        expect(runtime.outbox.rows.map(&:status)).to eq(["claimed"])

        rebooted = boot_sqlite(dir)
        expect { expect(rebooted.outbox.redrive!).to be_empty }
          .to output(/outbox row .*policy:Shop::RecordOrder.*claimed before the last crash.*redrive!\(claimed: true\)/m)
          .to_stderr
        expect(rebooted.outbox.log.last).to include(stalled: true, consumer: "policy:Shop::RecordOrder")
        expect(ledger(rebooted, "o-1")).to be_nil

        redriven = rebooted.outbox.redrive!(claimed: true)
        expect(redriven.size).to eq(1)
        expect(rebooted.outbox.rows.first).to be_delivered
        expect(rebooted.outbox.rows.first.attempts).to eq(2)
        expect(ledger(rebooted, "o-1")).not_to be_nil
      end
    end

    it "redrives pending rows as part of Loader.boot, after the dispatcher exists" do
      Dir.mktmpdir do |dir|
        runtime = boot_sqlite(dir)
        allow(runtime.outbox).to receive(:deliver).and_raise(Interrupt)
        expect { place(runtime, "o-1") }.to raise_error(Interrupt)

        rebooted = boot_sqlite(dir)
        Hecks::Runtime::Loader.redrive_outbox!(rebooted)
        expect(rebooted.outbox.rows.map(&:status)).to eq(["delivered"])
        expect(ledger(rebooted, "o-1")).not_to be_nil
      end
    end
  end

  describe "verify!" do
    it "warns when a domain with reactions is bound to an adapter that has no outbox" do
      Dir.mktmpdir do |dir|
        registry = Hecks::Runtime::Registry.new
        declare_shop(registry)
        Hecks.with_registry(registry) do
          Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/heki.adapter"))
          Hecks.hecksagon("Shop") { persisted_by "Heki" }
          Hecks.world("Shop") { persisted_by("Heki") { dir(dir) } }
        end

        expect do
          registry.verify!
        end.to output(%r{Shop declares policies/process_managers but its persistence adapter \(Heki\) has no outbox}).to_stderr
      end
    end

    it "stays quiet on Memory and SqlitePersistence, which both have one" do
      expect { boot_memory }.not_to output(/outbox/).to_stderr
      Dir.mktmpdir { |dir| expect { boot_sqlite(dir) }.not_to output(/outbox/).to_stderr }
    end
  end
end

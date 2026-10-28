require "spec_helper"
require "tmpdir"

# The transactional outbox (`Runtime::Outbox`) — a command's save, its
# events, and one row per (event, consumer) commit together; the
# dispatcher then drains those rows inline (pending → claimed →
# delivered | failed); a row left behind by a crash is found again on
# the next boot. `future-features.md` item 8.
RSpec.describe "the transactional outbox" do
  SQLITE_ADAPTER_FILE = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")

  OUTBOX_STALLED_ROW_WARNING =
    /outbox row .*policy:Shop::RecordOrder.*claimed before the last crash.*redrive!\(claimed: true\)/m
  OUTBOX_HEKI_WARNING = %r{Shop declares policies/process_managers but its persistence adapter \(Heki\) has no outbox}

  # Two aggregates, one policy between them: placing an Order owes the
  # Ledger a Record. The policy is the outbox's consumer; the Ledger row
  # is the proof it ran.
  OUTBOX_SHOP_DOMAIN = proc do
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

  def declare_shop(registry)
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(SQLITE_ADAPTER_FILE)
      Hecks.bluebook("Shop", &OUTBOX_SHOP_DOMAIN)
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

  def order_repository(runtime)
    runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate("Order"))
  end

  describe "on Memory" do
    let(:runtime) { boot_memory.tap { |booted| place(booted, "o-1") } }
    let(:row) { runtime.outbox.rows.first }

    # A pending copy of the held row, as if its fact were enqueued again.
    def pending_copy(held, **overrides)
      Hecks::Runtime::Outbox::Row.new(held.to_h.merge(id: nil, status: "pending", attempts: 0, **overrides))
    end

    def deliver_orphan
      orphan = pending_copy(row, consumer: "policy:Shop::Vanished", delivery_id: "#{row.event_uid}/policy:Shop::Vanished")
      stored, = order_repository(runtime).outbox_enqueue([orphan])
      runtime.outbox.deliver_row(stored, order_repository(runtime))
    end

    it "records one delivered row per (event, consumer)", :aggregate_failures do
      expect(runtime.outbox.rows.map(&:consumer)).to eq(["policy:Shop::RecordOrder"])
      expect(row).to be_delivered
      expect(row.kind).to eq("reaction")
      expect(row.attempts).to eq(1)
    end

    it "names the event and delivery of the row it records", :aggregate_failures do
      expect(row.event[:name]).to eq("OrderPlaced")
      expect(row.delivery_id).to eq("#{row.event_uid}/policy:Shop::RecordOrder")
    end

    it "runs the consumer inline", :aggregate_failures do
      expect(ledger(runtime, "o-1")).not_to be_nil
      expect(runtime.reactions.last).to include(policy: "RecordOrder", delivered: true)
    end

    it "writes no row for an event nothing listens to" do
      runtime.dispatch("Shop::Order.Touch", to: "o-1")

      expect(runtime.outbox.rows.map { |held| held.event[:name] }).to eq(["OrderPlaced"])
    end

    it "treats a re-enqueue of the same fact to the same consumer as a no-op", :aggregate_failures do
      expect(order_repository(runtime).outbox_enqueue([pending_copy(row)])).to eq([])
      expect(runtime.outbox.rows.size).to eq(1)
    end

    it "marks a row failed, with the defect, when its consumer cannot run at all", :aggregate_failures do
      expect(deliver_orphan).to be(false)

      failed = runtime.outbox.rows(status: "failed").first
      expect(failed).to have_attributes(consumer: "policy:Shop::Vanished", error: match(/WiringError.*Vanished/))
      expect(runtime.outbox.log.last).to include(outbox: failed.delivery_id, defect: true)
    end

    it "does not enqueue for a dry run, which commits nothing", :aggregate_failures do
      runtime = boot_memory
      expect(runtime.dry_run?("Shop::Order.Place", number: { value: "o-9" })).to be(true)
      expect(runtime.outbox.rows).to be_empty
    end
  end

  describe "on SqlitePersistence" do
    scratch_directory

    attr_reader :dir

    let(:runtime) { boot_sqlite(dir) }
    let(:rebooted) { boot_sqlite(dir) }

    # A crash is not a StandardError — nothing in the pipeline rescues it, the process is
    # simply gone. Stubbing `message` on the target to raise Interrupt simulates it mid-dispatch.
    def crash_placing(target, message)
      allow(target).to receive(message).and_raise(Interrupt)
      expect { place(runtime, "o-1") }.to raise_error(Interrupt)
    end

    # Moves every claim in the store back in time, so a claim made a moment ago stands as old as
    # `seconds`, as one left by a process that has long gone would.
    def claimed_ago(seconds)
      db = SQLite3::Database.new(File.join(dir, "shop.db"))
      db.execute("UPDATE hecks_outbox SET claimed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', ?) " \
                 "WHERE status = 'claimed'", ["-#{seconds} seconds"])
    ensure
      db&.close
    end

    def crash_leaving_stalled_claim
      crash_placing(runtime.instance_variable_get(:@policies), :react)
      claimed_ago(Hecks::Runtime::Outbox::STALLED_AFTER + 60)
    end

    it "commits the save, the event, and the outbox rows as one transaction", :aggregate_failures do
      repository = order_repository(runtime)
      allow(repository.adapter).to receive(:record_event).and_raise(RuntimeError, "disk full")

      expect { place(runtime, "o-1") }.to raise_error(RuntimeError, "disk full")
      expect([repository.find("o-1"), repository.entries, runtime.outbox.rows]).to eq([nil, [], []])
    end

    # Killing the relay's deliver before it claims anything leaves the row `pending`.
    it "keeps a pending row across a crash between commit and reaction", :aggregate_failures do
      crash_placing(runtime.outbox, :deliver)

      expect(runtime.outbox.rows.map(&:status)).to eq(["pending"])
      expect(ledger(runtime, "o-1")).to be_nil
    end

    it "does not run the reaction on the next boot until the row is redriven" do
      crash_placing(runtime.outbox, :deliver)

      expect(ledger(rebooted, "o-1")).to be_nil
    end

    it "redrives the pending row on the next boot", :aggregate_failures do
      crash_placing(runtime.outbox, :deliver)

      redriven = rebooted.outbox.redrive!

      expect(redriven.map(&:consumer)).to eq(["policy:Shop::RecordOrder"])
      expect(rebooted.outbox.rows.map(&:status)).to eq(["delivered"])
      expect(ledger(rebooted, "o-1")).not_to be_nil
    end

    it "records the redriven reaction as delivered" do
      crash_placing(runtime.outbox, :deliver)

      rebooted.outbox.redrive!

      expect(rebooted.reactions.last).to include(policy: "RecordOrder", delivered: true)
    end

    # Crash after the claim, inside the consumer — the outcome is genuinely unknown to the next
    # boot.
    it "leaves a claimed row behind when the crash comes after the claim" do
      crash_placing(runtime.instance_variable_get(:@policies), :react)

      expect(runtime.outbox.rows.map(&:status)).to eq(["claimed"])
    end

    it "surfaces a claimed row instead of redriving it, until told the redrive is safe", :aggregate_failures do
      crash_leaving_stalled_claim

      expect { expect(rebooted.outbox.redrive!).to be_empty }.to output(OUTBOX_STALLED_ROW_WARNING).to_stderr
      expect(rebooted.outbox.log.last).to include(stalled: true, consumer: "policy:Shop::RecordOrder")
      expect(ledger(rebooted, "o-1")).to be_nil
    end

    it "redrives a claimed row once told the redrive is safe", :aggregate_failures do
      crash_leaving_stalled_claim

      redriven = rebooted.outbox.redrive!(claimed: true)

      expect(redriven.size).to eq(1)
      expect(rebooted.outbox.rows.first).to be_delivered.and have_attributes(attempts: 2)
      expect(ledger(rebooted, "o-1")).not_to be_nil
    end

    it "redrives only the claimed row named by its delivery id", :aggregate_failures do
      crash_leaving_stalled_claim
      delivery_id = rebooted.outbox.rows.first.delivery_id

      expect(rebooted.outbox.redrive_row!(delivery_id).size).to eq(1)
      expect(rebooted.outbox.rows.first).to be_delivered
    end

    it "abandons a claimed row as failed without running its consumer", :aggregate_failures do
      crash_leaving_stalled_claim
      delivery_id = rebooted.outbox.rows.first.delivery_id

      rebooted.outbox.abandon_row!(delivery_id)

      expect(rebooted.outbox.rows.first).to be_failed.and have_attributes(error: /abandoned by an operator/)
      expect(ledger(rebooted, "o-1")).to be_nil
    end

    it "stops naming an abandoned row as stalled" do
      crash_leaving_stalled_claim
      rebooted.outbox.abandon_row!(rebooted.outbox.rows.first.delivery_id)

      expect { rebooted.outbox.redrive! }.not_to output.to_stderr
    end

    it "refuses to abandon a delivery id that no claimed row has" do
      crash_leaving_stalled_claim

      expect { rebooted.outbox.abandon_row!("nope") }
        .to raise_error(Hecks::Runtime::NotFound, /no claimed outbox row "nope"/)
    end

    it "refuses a delivery id that no claimed row has" do
      crash_leaving_stalled_claim

      expect { rebooted.outbox.redrive_row!("nope") }
        .to raise_error(Hecks::Runtime::NotFound, /no claimed outbox row "nope"/)
    end

    # A claim made a moment ago is a reaction running in another process, not one a crash left.
    context "when the claim is recent" do
      before { crash_placing(runtime.instance_variable_get(:@policies), :react) }

      it "does not name a row claimed a moment ago as stalled" do
        expect { rebooted.outbox.redrive!(claimed: true) }.not_to output.to_stderr
      end

      it "redrives nothing for a row claimed a moment ago" do
        expect(rebooted.outbox.redrive!(claimed: true)).to be_empty
      end

      it "leaves a row claimed a moment ago claimed, and does not run it", :aggregate_failures do
        rebooted.outbox.redrive!(claimed: true)

        expect(rebooted.outbox.rows.first).to be_claimed
        expect(ledger(rebooted, "o-1")).to be_nil
      end

      it "refuses to redrive it by name, saying it is in flight" do
        expect { rebooted.outbox.redrive_row!(rebooted.outbox.rows.first.delivery_id) }
          .to raise_error(Hecks::Runtime::NotFound, /is in flight, claimed \d+s ago/)
      end

      it "refuses to abandon it by name, saying it is in flight" do
        expect { rebooted.outbox.abandon_row!(rebooted.outbox.rows.first.delivery_id) }
          .to raise_error(Hecks::Runtime::NotFound, /is in flight/)
      end

      it "names it as stalled once it has stood claimed past the limit", :aggregate_failures do
        claimed_ago(Hecks::Runtime::Outbox::STALLED_AFTER + 60)

        expect { rebooted.outbox.redrive! }.to output(OUTBOX_STALLED_ROW_WARNING).to_stderr
        expect(rebooted.outbox.rows.first).to be_stalled
      end
    end

    it "redrives pending rows as part of Loader.boot, after the dispatcher exists", :aggregate_failures do
      crash_placing(runtime.outbox, :deliver)

      Hecks::Runtime::Loader.redrive_outbox!(rebooted)

      expect(rebooted.outbox.rows.map(&:status)).to eq(["delivered"])
      expect(ledger(rebooted, "o-1")).not_to be_nil
    end
  end

  describe "verify!" do
    def heki_registry(dir)
      registry = Hecks::Runtime::Registry.new
      declare_shop(registry)
      Hecks.with_registry(registry) do
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/heki.adapter"))
        Hecks.hecksagon("Shop") { persisted_by "Heki" }
        Hecks.world("Shop") { persisted_by("Heki") { dir(dir) } }
      end
      registry
    end

    it "warns when a domain with reactions is bound to an adapter that has no outbox" do
      Dir.mktmpdir do |dir|
        registry = heki_registry(dir)

        expect { registry.verify! }.to output(OUTBOX_HEKI_WARNING).to_stderr
      end
    end

    it "stays quiet on Memory and SqlitePersistence, which both have one", :aggregate_failures do
      expect { boot_memory }.not_to output(/outbox/).to_stderr
      Dir.mktmpdir { |dir| expect { boot_sqlite(dir) }.not_to output(/outbox/).to_stderr }
    end
  end
end

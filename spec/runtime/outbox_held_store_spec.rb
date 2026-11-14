require "spec_helper"
require "tmpdir"
require "sqlite3"

# A command's reactions run after its own write has committed. When another process holds the
# store past the wait while a reaction is claimed, run or settled, the command still answers
# its own saved write: the held reaction is said on stderr, never raised, and its outbox row is
# left where the next boot runs it whenever the reaction wrote nothing.
RSpec.describe "a reaction that finds the store held" do
  HELD_SQLITE_ADAPTER = File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter")

  # Placing an Order owes the Ledger a Record: the policy is the reaction the store is held for.
  HELD_SHOP_DOMAIN = proc do
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

  around do |example|
    @dir = Dir.mktmpdir("hecks-held-store-")
    example.run
  ensure
    let_go
    FileUtils.remove_entry(@dir) if @dir
  end

  def path = File.join(@dir, "shop.db")

  def declare(registry)
    file = path
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(HELD_SQLITE_ADAPTER)
      Hecks.bluebook("Shop", &HELD_SHOP_DOMAIN)
      Hecks.hecksagon("Shop") { persisted_by "SqlitePersistence" }
      Hecks.world("Shop") { persisted_by("SqlitePersistence") { database(file) } }
    end
  end

  def boot
    registry = Hecks::Runtime::Registry.new
    declare(registry)
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot }

  # The wait is cut to 50 ms, so a held file is found at once and not after ten seconds.
  before { stub_const("Hecks::Adapters::Sqlite::BUSY_TIMEOUT_MS", 50) }

  def repository(name) = runtime.registry.repository("Shop", runtime.registry.bluebook("Shop").aggregate(name))

  def orders = repository("Order")

  def ledger = repository("Ledger")

  # Another process's lock on the file, held until `let_go`. It is taken once an example, so a
  # later redrive of the same row finds the store free.
  def hold
    return if @held

    @held = true
    @holder = SQLite3::Database.new(path)
    @holder.execute("BEGIN EXCLUSIVE")
  end

  def let_go
    return unless @holder

    @holder.execute("COMMIT")
    @holder.close
    @holder = nil
  end

  # Takes the lock just before the Order store runs `step`, as another process would.
  def hold_before(step)
    allow(orders).to receive(step).and_wrap_original do |original, *args, **options|
      hold
      original.call(*args, **options)
    end
  end

  # Takes the lock just after the Order store has claimed the row, so the reaction itself meets it.
  def hold_after_claim
    allow(orders).to receive(:outbox_claim).and_wrap_original do |original, id|
      original.call(id).tap { hold }
    end
  end

  # Lets the lock go as the Order store settles, so a row can be put back.
  def let_go_at_settle
    allow(orders).to receive(:outbox_settle).and_wrap_original do |original, *args, **options|
      let_go
      original.call(*args, **options)
    end
  end

  # Places the order with stderr captured; answers the dispatch result and what stderr said.
  def place
    said = StringIO.new
    original = $stderr
    $stderr = said
    [runtime.dispatch("Shop::Order.Place", with: { number: { value: "o-1" } }), said.string]
  ensure
    $stderr = original
  end

  def row = orders.outbox_rows.first

  def clean?(result) = result.reaction_defects.empty? && result.blocking_reactions.empty? && result.refused_reactions.empty?

  describe "held before the row is claimed" do
    before { hold_before(:outbox_claim) }

    it "answers the saved write and names the reaction on stderr", :aggregate_failures do
      result, said = place
      expect(clean?(result)).to be(true)
      expect(result.events.map(&:name)).to eq(["OrderPlaced"])
      expect(said).to match(/policy:Shop::RecordOrder on OrderPlaced.*store was busy.*pending/m)
    end

    it "leaves the row pending, and the next redrive runs the reaction once", :aggregate_failures do
      place
      let_go
      expect([orders.find("o-1").nil?, row.status, ledger.find("o-1")]).to eq([false, "pending", nil])
      expect(runtime.outbox.redrive!.size).to eq(1)
      expect([row.status, ledger.count]).to eq(["delivered", 1])
    end
  end

  describe "held when the reaction first opens its store" do
    before { hold_after_claim }

    it "records the reaction as one that wrote nothing and leaves its row for a redrive", :aggregate_failures do
      let_go_at_settle
      place
      expect(runtime.reactions.last).to include(held: true, unwritten: true)
      expect([row.status, runtime.outbox.redrive!.size, ledger.count]).to eq(["pending", 1, 1])
    end
  end

  describe "held when the reaction's own write begins" do
    before do
      ledger
      hold_after_claim
    end

    it "puts the row back to pending when the store lets go, and a redrive runs it", :aggregate_failures do
      let_go_at_settle
      result, said = place
      expect([clean?(result), row.status, ledger.find("o-1")]).to eq([true, "pending", nil])
      expect(said).to include("reaction RecordOrder on OrderPlaced was held")
      expect([runtime.outbox.redrive!.size, row.status, ledger.count]).to eq([1, "delivered", 1])
    end

    it "leaves the row claimed and names how to run it when it cannot be put back", :aggregate_failures do
      result, said = place
      let_go
      expect([clean?(result), row.status, ledger.find("o-1")]).to eq([true, "claimed", nil])
      expect(said).to match(/wrote nothing and the row could not be put back.*Operation\.RedriveOutbox/m)
    end

    it "records the held reaction as one that wrote nothing, not as a defect" do
      place
      expect(runtime.reactions.last).to include(policy: "RecordOrder", delivered: false, held: true, unwritten: true)
    end
  end

  describe "held after the reaction's write committed" do
    # The Ledger's write commits, and the store is found held straight after it.
    before do
      allow(ledger).to receive(:transaction).and_wrap_original do |original, &block|
        original.call(&block)
        raise SQLite3::BusyException, "database is locked"
      end
    end

    it "does not run the reaction again: the row is settled and the record is there once", :aggregate_failures do
      result, = place
      expect([clean?(result), row.status, ledger.count]).to eq([true, "delivered", 1])
      expect(runtime.reactions.last).to include(held: true, unwritten: false)
      expect(runtime.outbox.redrive!).to eq([])
    end
  end

  describe "held while the row is settled" do
    before { hold_before(:outbox_settle) }

    it "answers the saved write and leaves the row claimed, its reaction run", :aggregate_failures do
      result, said = place
      let_go
      expect([clean?(result), row.status, ledger.count]).to eq([true, "claimed", 1])
      expect(said).to include("Its reaction ran; the row stays claimed and is not run again.")
    end
  end

  describe "through the launcher with --wait" do
    before { hold_before(:outbox_claim) }

    def run_place
      argv = ["Order.place!", "number=o-1", "--wait"]
      answer = nil
      expect { answer = Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: argv, program: "hecks run") }
        .to output(/store was busy/).to_stderr
      answer
    end

    it "answers the saved record with status 0 and no failure reason", :aggregate_failures do
      text, status, reason = run_place
      expect([status, reason]).to eq([Hecks::Adapters::Driving::ExitStatus::ANSWERED, nil])
      expect(JSON.parse(text).fetch("events")).to eq(["OrderPlaced"])
      expect(text).not_to include("database is locked")
    end
  end

  describe "a command whose own write finds the store held" do
    it "fails by name, since nothing was saved", :aggregate_failures do
      runtime
      hold
      expect { place }.to raise_error(Hecks::Runtime::StoreHeld, /locked/)
      let_go
      expect(orders.find("o-1")).to be_nil
    end
  end
end

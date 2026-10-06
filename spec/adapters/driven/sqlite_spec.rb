require "hecks"
require "tmpdir"

RSpec.describe Hecks::Adapters::Sqlite do
  around do |example|
    @dir = Dir.mktmpdir("hecks-sqlite-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  # Booted once per file — solely to read the static "Order" IR back
  # out; every real mutation below goes to the adapter's own per-example
  # tmpdir database (the `around` above), so a shared boot is safe.
  before(:context) { @aggregate = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  let(:aggregate) { @aggregate }

  let(:adapter) do
    described_class.new(aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir)
  end

  def instance(id, **fields)
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecks::Runtime::Value.for(aggregate, name, value) }
    built
  end

  def reopened_adapter = described_class.new(aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir)

  def raw_db = adapter.instance_variable_get(:@db)

  def margherita
    instance("p1", name: { value: "Margherita" },
                   pizza: { price_cents: { cents: 1200 }, size: { value: "small" } }, status: "available")
  end

  def pizza_purchased(id, customer, at)
    Hecks::Runtime::Event.new(name: "PizzaPurchased", aggregate: "Pizza", id: id,
                              payload: { customer: customer }, occurred_at: at)
  end

  def event_summary(events) = events.map { |item| [item.name, item.id, item.payload] }

  it "creates its database where the settings say" do
    adapter
    expect(File.exist?(File.join(@dir, "pizzas.db"))).to be(true)
  end

  # Read through the gem the adapter itself uses, so the spec does not need the sqlite3 CLI.
  def order_schema
    db = SQLite3::Database.new(File.join(@dir, "pizzas.db"))
    db.execute("SELECT sql FROM sqlite_master WHERE tbl_name = 'order'").flatten.join("\n")
  ensure
    db&.close
  end

  it "projects its schema from the aggregate IR" do
    adapter

    expect(order_schema).to include(%("pizza" TEXT), %("name" TEXT), %("toppings" TEXT), "id TEXT PRIMARY KEY")
  end

  # An adapter over a copy of Order whose table is named `order`, a SQL reserved word, holding
  # one record.
  def reserved_word_adapter
    reserved = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order").dup
    def reserved.storage_name = "order"

    described_class.new(aggregate: reserved, settings: { database: "reserved.db" }, root: @dir).tap do |store|
      built = Hecks::Runtime::Instance.new(aggregate: reserved, id: "o1")
      built[:name] = Hecks::Runtime::Value.for(reserved, :name, { value: "Margherita" })
      store.save(built)
    end
  end

  it "stores an aggregate whose name is a SQL reserved word", :aggregate_failures do
    store = reserved_word_adapter

    expect(store.find("o1").name.to_h).to eq(value: "Margherita")
    expect(store.count).to eq(1)
  end

  it "saves and finds one back", :aggregate_failures do
    adapter.save(margherita)

    found = adapter.find("p1")
    expect(found.name.to_h).to eq(value: "Margherita")
    expect(found.pizza.to_h).to eq(price_cents: { cents: 1200 }, size: { value: "small" })
    expect(found.status).to eq("available")
  end

  it "round-trips a list of value objects through its JSON column", :aggregate_failures do
    adapter.save(instance("p1", toppings: [{ name: "Basil", amount: 3 }]))

    # ADR 0047/0055 — toppings elements are real Hecks::Runtime::Value
    # instances now (Value::Coercion#hydrate_entity_list was fixed to
    # hydrate value-object lists, not just entity ones), same as
    # `found.name`/`found.pizza` above already are for a scalar
    # composite attribute — compared via `.to_h`, matching those.
    toppings = adapter.find("p1").toppings
    expect(toppings).to all(be_a(Hecks::Runtime::Value))
    expect(toppings.map(&:to_h)).to eq([{ name: "Basil", amount: 3 }])
  end

  it "answers nil for an id it never stored" do
    expect(adapter.find("nope")).to be_nil
  end

  def journalled_statuses
    raw_db.execute('SELECT state FROM "order_entries" ORDER BY sequence')
          .map { |entry| JSON.parse(entry["state"]).fetch("status") }
  end

  it "keeps every write and reads the last entry", :aggregate_failures do
    adapter.save(instance("p1", status: "available"))
    adapter.save(instance("p1", status: "sold"))

    expect([adapter.count, adapter.find("p1").status]).to eq([1, "sold"])
    expect(journalled_statuses).to eq(%w[available sold])
  end

  it "lists everything it holds", :aggregate_failures do
    adapter.save(instance("p1", name: { value: "Margherita" }))
    adapter.save(instance("p2", name: { value: "Bare" }))

    expect(adapter.all.map(&:id)).to contain_exactly("p1", "p2")
    expect(adapter.count).to eq(2)
  end

  it "pushes an 'in' where-clause down to SQL, matching any of the comma-separated list" do
    %w[Margherita Diavola Bare].each_with_index { |label, index| adapter.save(instance("p#{index + 1}", name: { value: label })) }
    where = Hecks::QuerySpecification::Common::WhereClause.new(field: "name", op: :in, value: "Margherita,Diavola")

    expect(adapter.query(Hecks::Bluebook::Query.new(name: "ByName", wheres: [where]), {}).map(&:id))
      .to contain_exactly("p1", "p2")
  end

  it "deletes through the append-only log and materialized table", :aggregate_failures do
    adapter.save(instance("p1", name: { value: "Temporary" }))

    expect(adapter.delete("p1")).to be(true)
    expect(adapter.find("p1")).to be_nil
    expect(adapter.entries.last.operation).to eq("delete")
    expect(adapter.delete("missing")).to be(true)
  end

  def mirror_rows(condition) = raw_db.execute("SELECT mirrors FROM \"order_entries\" WHERE #{condition}")

  it "stores an absent mirrors hash as a real SQL NULL, not the JSON text \"null\"", :aggregate_failures do
    adapter.save(instance("p1", status: "available"))

    expect(mirror_rows("mirrors IS NULL").size).to eq(1)
    expect(mirror_rows("mirrors = 'null'")).to be_empty
  end

  context "with a real mirrors hash appended" do
    before do
      adapter.append(Hecks::Ports::Persistence::Entry.new(operation: "save", id: "p2", state: { status: "available" },
                                                          mirrors: { replica: "eu" }))
    end

    it "reads it back" do
      expect(adapter.entries.last.mirrors).to eq("replica" => "eu")
    end

    it "still stores it as JSON text" do
      row = raw_db.get_first_row('SELECT mirrors FROM "order_entries" WHERE aggregate_id = ?', ["p2"])

      expect(row["mirrors"]).to eq(JSON.generate(replica: "eu"))
    end
  end

  it "records and reloads domain events" do
    adapter.record_event(pizza_purchased("p1", "c1", "2026-01-01T00:00:00Z"))

    expect(event_summary(adapter.events)).to eq([["PizzaPurchased", "p1", { customer: "c1" }]])
  end

  def record_events_of_two_pizzas_and_an_order
    adapter.record_event(pizza_purchased("p1", "c1", "2026-01-01T00:00:00Z"))
    adapter.record_event(pizza_purchased("p2", "c2", "2026-01-01T00:00:01Z"))
    adapter.record_event(Hecks::Runtime::Event.new(name: "OrderPlaced", aggregate: "Order", id: "p1",
                                                   payload: { total: 12 }, occurred_at: "2026-01-01T00:00:02Z"))
  end

  it "reads back only one record's events, not the whole shared table" do
    record_events_of_two_pizzas_and_an_order

    expect(event_summary(adapter.events_for(aggregate: "Pizza", id: "p1"))).to eq([["PizzaPurchased", "p1", { customer: "c1" }]])
  end

  # Drops the entry table of a fresh database and recreates it as it was before the operation and
  # mirror columns existed.
  def make_legacy_database
    reopened_legacy = described_class.new(aggregate: aggregate, settings: { database: "legacy.db" }, root: @dir)
    db = SQLite3::Database.new(File.join(@dir, "legacy.db"))
    db.execute('DROP TABLE "order_entries"')
    db.execute('CREATE TABLE "order_entries" (sequence INTEGER PRIMARY KEY AUTOINCREMENT, ' \
               "aggregate_id TEXT NOT NULL, state TEXT NOT NULL)")
    reopened_legacy
  ensure
    db&.close
  end

  it "upgrades an entry table created before operation and mirror columns" do
    make_legacy_database
    upgraded = described_class.new(aggregate: aggregate, settings: { database: "legacy.db" }, root: @dir)
    upgraded.save(instance("p1", name: { value: "Legacy" }))

    expect(upgraded.entries.last.operation).to eq("save")
  end

  it "outlives the adapter that wrote it" do
    adapter.save(instance("p1", name: { value: "Margherita" }, status: "sold"))

    expect(reopened_adapter.find("p1").status).to eq("sold")
  end

  describe "the replay checkpoint (bounds AppendOnly#recover!'s replay to what a restart missed)" do
    it "advances with every project, so entries_since(checkpoint) is empty right after a write" do
      adapter.save(instance("p1", status: "available"))

      expect(adapter.entries_since(adapter.checkpoint)).to eq([])
    end

    it "starts at zero for a table that has never been checkpointed" do
      expect(adapter.checkpoint).to eq(0)
    end

    it "lets entries_since skip everything at or before a given sequence" do
      adapter.save(instance("p1", status: "available"))
      first_checkpoint = adapter.checkpoint
      adapter.save(instance("p2", status: "available"))

      expect(adapter.entries_since(first_checkpoint).map(&:id)).to eq(["p2"])
    end

    it "still catches up a real gap: an entry journaled without being projected is picked up", :aggregate_failures do
      entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "p1", state: { status: "available" })
      adapter.append(entry)
      expect(adapter.find("p1")).to be_nil

      Hecks::Ports::Persistence::AppendOnly.new(adapter).recover!

      expect(adapter.find("p1").status).to eq("available")
    end
  end

  describe "compact_entries! (deletes old journal rows a :refresh projection no longer needs)" do
    it "starts at zero when nothing has ever been compacted" do
      expect(adapter.compacted_through).to eq(0)
    end

    context "with two entries compacted through the checkpoint" do
      before do
        adapter.save(instance("p1", status: "available"))
        adapter.save(instance("p2", status: "available"))
        @through = adapter.checkpoint
      end

      it "reports how many rows it deleted" do
        expect(adapter.compact_entries!(through: @through)).to eq(2)
      end

      it "empties the journal, leaving the aggregate table untouched", :aggregate_failures do
        adapter.compact_entries!(through: @through)

        expect(adapter.entries).to eq([])
        expect(adapter.find("p1").status).to eq("available")
      end

      it "records how far it compacted" do
        adapter.compact_entries!(through: @through)

        expect(adapter.compacted_through).to eq(@through)
      end
    end

    it "leaves rows after through in the journal" do
      adapter.save(instance("p1", status: "available"))
      first = adapter.checkpoint
      adapter.save(instance("p2", status: "available"))

      adapter.compact_entries!(through: first)

      expect(adapter.entries.map(&:id)).to eq(["p2"])
    end

    context "with a first entry compacted and a second saved" do
      before do
        adapter.save(instance("p1", status: "available"))
        adapter.compact_entries!(through: adapter.checkpoint)
        adapter.save(instance("p2", status: "available"))
        @high_water = adapter.checkpoint
      end

      it "never moves compacted_through backwards" do
        [@high_water, 0].each { |through| adapter.compact_entries!(through: through) }

        expect(adapter.compacted_through).to eq(@high_water)
      end
    end
  end

  describe "the optional saga-persistence capability (§2/§3/§4)" do
    it "saves a saga instance and reads it back through each_saga" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1",
                        state: "awaiting_credit", memory: { amount: 100 })

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "awaiting_credit", { amount: 100 }, []]])
    end

    it "replaces on a repeated save for the same (process_manager, correlation)" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "next", memory: { step: 2 })

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "next", { step: 2 }, []]])
    end

    it "deletes a saga instance" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.delete_saga(process_manager: "Onboarding", correlation: "c1")

      expect(adapter.each_saga.to_a).to eq([])
    end

    it "outlives the adapter that wrote it, same as an aggregate's own state" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: { a: 1 })

      expect(reopened_adapter.each_saga.to_a).to eq([["Onboarding", "c1", "start", { a: 1 }, []]])
    end

    it "isolates sagas by domain within one shared database file", :aggregate_failures do
      other = described_class.new(aggregate: aggregate, settings: { database: "pizzas.db", domain: "OtherDomain" }, root: @dir)
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      other.save_saga(process_manager: "Onboarding", correlation: "c1", state: "different", memory: {})

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "start", {}, []]])
      expect(other.each_saga.to_a).to eq([["Onboarding", "c1", "different", {}, []]])
    end
  end
end

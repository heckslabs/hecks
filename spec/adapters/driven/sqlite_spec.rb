require "hecks"
require "tmpdir"

RSpec.describe Hecks::Adapters::Sqlite do
  around do |example|
    @dir = Dir.mktmpdir("hecks-sqlite-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  # Booted ONCE per file — only used to read the static "Order" IR back
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

  it "creates its database where the settings say" do
    adapter
    expect(File.exist?(File.join(@dir, "pizzas.db"))).to be(true)
  end

  it "projects its schema from the aggregate IR" do
    adapter
    schema = `sqlite3 #{File.join(@dir, "pizzas.db")} ".schema order"`

    expect(schema).to include(%("pizza" TEXT))
    expect(schema).to include(%("name" TEXT))
    expect(schema).to include(%("toppings" TEXT))
    expect(schema).to include("id TEXT PRIMARY KEY")
  end

  it "stores an aggregate whose name is a SQL reserved word" do
    reserved = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order").dup
    def reserved.storage_name = "order"

    adapter = described_class.new(
      aggregate: reserved, settings: { database: "reserved.db" }, root: @dir
    )

    built = Hecks::Runtime::Instance.new(aggregate: reserved, id: "o1")
    built[:name] = Hecks::Runtime::Value.for(reserved, :name, { value: "Margherita" })
    adapter.save(built)

    expect(adapter.find("o1").name.to_h).to eq(value: "Margherita")
    expect(adapter.count).to eq(1)
  end

  it "saves and finds one back" do
    adapter.save(instance("p1", name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 } }, status: "available"))

    found = adapter.find("p1")
    expect(found.name.to_h).to eq(value: "Margherita")
    expect(found.pizza.to_h).to eq(price_cents: { cents: 1200 })
    expect(found.status).to eq("available")
  end

  it "round-trips a list of value objects through its JSON column" do
    adapter.save(instance("p1", toppings: [{ name: "Basil", amount: 3 }]))

    expect(adapter.find("p1").toppings).to eq([{ name: "Basil", amount: 3 }])
  end

  it "answers nil for an id it never stored" do
    expect(adapter.find("nope")).to be_nil
  end

  it "keeps every write and reads the last entry" do
    adapter.save(instance("p1", status: "available"))
    adapter.save(instance("p1", status: "sold"))

    expect(adapter.count).to eq(1)
    expect(adapter.find("p1").status).to eq("sold")
    entries = adapter.instance_variable_get(:@db).execute('SELECT state FROM "order_entries" ORDER BY sequence')
    expect(entries.map { |entry| JSON.parse(entry["state"]).fetch("status") }).to eq(%w[available sold])
  end

  it "lists everything it holds" do
    adapter.save(instance("p1", name: { value: "Margherita" }))
    adapter.save(instance("p2", name: { value: "Bare" }))

    expect(adapter.all.map(&:id)).to contain_exactly("p1", "p2")
    expect(adapter.count).to eq(2)
  end

  it "pushes an 'in' where-clause down to SQL, matching any of the comma-separated list" do
    adapter.save(instance("p1", name: { value: "Margherita" }))
    adapter.save(instance("p2", name: { value: "Diavola" }))
    adapter.save(instance("p3", name: { value: "Bare" }))

    where = Hecks::QuerySpecification::Common::WhereClause.new(
      field: "name", op: :in, value: "Margherita,Diavola"
    )
    declared = Hecks::Bluebook::Query.new(name: "ByName", wheres: [where])

    expect(adapter.query(declared, {}).map(&:id)).to contain_exactly("p1", "p2")
  end

  it "pushes an 'in' where-clause matching nothing when the list is empty" do
    adapter.save(instance("p1", name: { value: "Margherita" }))

    where = Hecks::QuerySpecification::Common::WhereClause.new(field: "name", op: :in, value: "")
    declared = Hecks::Bluebook::Query.new(name: "ByName", wheres: [where])

    expect(adapter.query(declared, {})).to be_empty
  end

  it "deletes through the append-only log and materialized table" do
    adapter.save(instance("p1", name: { value: "Temporary" }))

    expect(adapter.delete("p1")).to be(true)
    expect(adapter.find("p1")).to be_nil
    expect(adapter.entries.last.operation).to eq("delete")
    expect(adapter.delete("missing")).to be(true)
  end

  it "stores an absent mirrors hash as a real SQL NULL, not the JSON text \"null\"" do
    adapter.save(instance("p1", status: "available"))

    db = adapter.instance_variable_get(:@db)
    null_rows = db.execute('SELECT mirrors FROM "order_entries" WHERE mirrors IS NULL')
    expect(null_rows.size).to eq(1)

    text_rows = db.execute("SELECT mirrors FROM \"order_entries\" WHERE mirrors = 'null'")
    expect(text_rows).to be_empty
  end

  it "still stores a real mirrors hash as JSON text, and reads it back" do
    entry = Hecks::Ports::Persistence::Entry.new(
      operation: "save", id: "p2", state: { status: "available" }, mirrors: { replica: "eu" }
    )
    adapter.append(entry)

    expect(adapter.entries.last.mirrors).to eq("replica" => "eu")

    db = adapter.instance_variable_get(:@db)
    row = db.get_first_row('SELECT mirrors FROM "order_entries" WHERE aggregate_id = ?', ["p2"])
    expect(row["mirrors"]).to eq(JSON.generate(replica: "eu"))
  end

  it "records and reloads domain events" do
    event = Hecks::Runtime::Event.new(
      name: "PizzaPurchased", aggregate: "Pizza", id: "p1",
      payload: { customer: "c1" }, occurred_at: "2026-01-01T00:00:00Z"
    )
    adapter.record_event(event)

    expect(adapter.events.map { |item| [item.name, item.id, item.payload] })
      .to eq([["PizzaPurchased", "p1", { customer: "c1" }]])
  end

  it "upgrades an entry table created before operation and mirror columns" do
    path = File.join(@dir, "legacy.db")
    described_class.new(aggregate: aggregate, settings: { database: "legacy.db" }, root: @dir)
    db = SQLite3::Database.new(path)
    db.execute('DROP TABLE "order_entries"')
    db.execute('CREATE TABLE "order_entries" (sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_id TEXT NOT NULL, state TEXT NOT NULL)')
    db.close

    upgraded = described_class.new(aggregate: aggregate, settings: { database: "legacy.db" }, root: @dir)
    upgraded.save(instance("p1", name: { value: "Legacy" }))
    expect(upgraded.entries.last.operation).to eq("save")
  end

  it "outlives the adapter that wrote it" do
    adapter.save(instance("p1", name: { value: "Margherita" }, status: "sold"))

    reopened = described_class.new(
      aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir
    )

    expect(reopened.find("p1").status).to eq("sold")
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

      reopened = described_class.new(aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir)
      expect(reopened.each_saga.to_a).to eq([["Onboarding", "c1", "start", { a: 1 }, []]])
    end

    it "isolates sagas by domain within one shared database file" do
      other = described_class.new(aggregate: aggregate, settings: { database: "pizzas.db", domain: "OtherDomain" }, root: @dir)
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      other.save_saga(process_manager: "Onboarding", correlation: "c1", state: "different", memory: {})

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "start", {}, []]])
      expect(other.each_saga.to_a).to eq([["Onboarding", "c1", "different", {}, []]])
    end

    # `settings[:domain] || settings["domain"] || aggregate.name` used to
    # coerce a genuinely stored `false` at :domain into the aggregate-name
    # fallback — indistinguishable from :domain being absent entirely.
    it "reads a `false`-valued :domain setting back as itself, not the aggregate-name fallback" do
      falsy_domain = described_class.new(
        aggregate: aggregate, settings: { database: "pizzas.db", domain: false }, root: @dir
      )

      expect(falsy_domain.instance_variable_get(:@domain)).to eq("false")
    end
  end
end

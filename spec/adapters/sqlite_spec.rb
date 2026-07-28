require "hecksagain"
require "tmpdir"

RSpec.describe Hecksagain::Adapters::Sqlite do
  around do |example|
    @dir = Dir.mktmpdir("hecksagain-sqlite-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  let(:aggregate) do
    boot_in_memory.registry.bluebook("Pizzas").aggregate("Pizza")
  end

  let(:adapter) do
    described_class.new(aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir)
  end

  def instance(id, **fields)
    built = Hecksagain::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = value }
    built
  end

  it "creates its database where the settings say" do
    adapter
    expect(File.exist?(File.join(@dir, "pizzas.db"))).to be(true)
  end

  it "projects its schema from the aggregate IR" do
    adapter
    schema = `sqlite3 #{File.join(@dir, 'pizzas.db')} ".schema pizza"`

    expect(schema).to include(%("price_cents" INTEGER)) 
    expect(schema).to include(%("name" TEXT))           
    expect(schema).to include(%("toppings" TEXT))       
    expect(schema).to include("id TEXT PRIMARY KEY")
  end

  it "stores an aggregate whose name is a SQL reserved word" do
    reserved = boot_in_memory.registry.bluebook("Pizzas").aggregate("Pizza").dup
    def reserved.storage_name = "order"

    adapter = described_class.new(
      aggregate: reserved, settings: { database: "reserved.db" }, root: @dir
    )

    built = Hecksagain::Runtime::Instance.new(aggregate: reserved, id: "o1")
    built[:name] = "Margherita"
    adapter.save(built)

    expect(adapter.find("o1").name).to eq("Margherita")
    expect(adapter.count).to eq(1)
  end

  it "saves and finds one back" do
    adapter.save(instance("p1", name: "Margherita", price_cents: 1200, status: "available"))

    found = adapter.find("p1")
    expect(found.name).to eq("Margherita")
    expect(found.price_cents).to eq(1200)
    expect(found.status).to eq("available")
  end

  it "round-trips a list of value objects through its JSON column" do
    adapter.save(instance("p1", toppings: [{ name: "Basil", amount: 3 }]))

    expect(adapter.find("p1").toppings).to eq([{ name: "Basil", amount: 3 }])
  end

  it "answers nil for an id it never stored" do
    expect(adapter.find("nope")).to be_nil
  end

  it "upserts rather than duplicating" do
    adapter.save(instance("p1", status: "available"))
    adapter.save(instance("p1", status: "sold"))

    expect(adapter.count).to eq(1)
    expect(adapter.find("p1").status).to eq("sold")
  end

  it "lists everything it holds" do
    adapter.save(instance("p1", name: "Margherita"))
    adapter.save(instance("p2", name: "Bare"))

    expect(adapter.all.map(&:id)).to contain_exactly("p1", "p2")
    expect(adapter.count).to eq(2)
  end

  it "outlives the adapter that wrote it" do
    adapter.save(instance("p1", name: "Margherita", status: "sold"))

    reopened = described_class.new(
      aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir
    )

    expect(reopened.find("p1").status).to eq("sold")
  end
end

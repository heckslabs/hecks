require "hecksagain"

# Runs only when a Postgres server is reachable (any local default
# install will do). CI and pre-push provide one the same way bin/parity
# does: a local instance or `docker run postgres`, named through
# HECKS_PARITY_POSTGRES for the parity gate — this spec manages its own
# scratch database and needs no configuration at all.
postgres_available =
  begin
    PG.connect(dbname: "postgres").close
    true
  rescue PG::Error
    false
  end

RSpec.describe Hecksagain::Adapters::Postgres,
               skip: (postgres_available ? false : "no reachable Postgres — start one to run this spec") do
  SPEC_DB = "hecksagain_adapter_spec".freeze

  before(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SPEC_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{SPEC_DB}")
    admin.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{SPEC_DB} WITH (FORCE)")
    admin.close
  end

  before do
    scrub = PG.connect(dbname: SPEC_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  let(:aggregate) do
    boot_in_memory.registry.bluebook("Pizzas").aggregate("Pizza")
  end

  let(:adapter) do
    described_class.new(aggregate: aggregate, settings: { database: SPEC_DB })
  end

  def instance(id, **fields)
    built = Hecksagain::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecksagain::Runtime::Value.for(aggregate, name, value) }
    built
  end

  it "refuses a binding that declares no database" do
    expect { described_class.new(aggregate: aggregate, settings: {}) }
      .to raise_error(Hecksagain::Runtime::WiringError, /declares no "database"/)
  end

  it "refuses loudly when the declared database is unreachable" do
    expect { described_class.new(aggregate: aggregate, settings: { database: "postgres://localhost:1/nowhere" }) }
      .to raise_error(Hecksagain::Runtime::WiringError, /cannot bind Postgres at postgres:\/\/localhost:1\/nowhere for Pizza/)
  end

  it "saves and finds one back through the jsonb head" do
    adapter.save(instance("p1", name: { value: "Margherita" }, price_cents: { cents: 1200 }, status: "available"))

    found = adapter.find("p1")
    expect(found.name.to_h).to eq(value: "Margherita")
    expect(found.price_cents.to_h).to eq(cents: 1200)
    expect(found.status).to eq("available")
  end

  it "round-trips a list of value objects through jsonb" do
    adapter.save(instance("p1", toppings: [{ name: "Basil", amount: 3 }]))

    expect(adapter.find("p1").toppings).to eq([{ name: "Basil", amount: 3 }])
  end

  it "answers nil for an id it never stored" do
    expect(adapter.find("nope")).to be_nil
  end

  it "keeps every write in the journal and reads the head from the last" do
    adapter.save(instance("p1", status: "available"))
    adapter.save(instance("p1", status: "sold"))

    expect(adapter.count).to eq(1)
    expect(adapter.find("p1").status).to eq("sold")
    expect(adapter.entries.map { |entry| entry.state[:status] }).to eq(%w[available sold])
  end

  it "lists everything it holds" do
    adapter.save(instance("p1", name: { value: "Margherita" }))
    adapter.save(instance("p2", name: { value: "Bare" }))

    expect(adapter.all.map(&:id)).to contain_exactly("p1", "p2")
    expect(adapter.count).to eq(2)
  end

  it "deletes through the append-only journal and the head" do
    adapter.save(instance("p1", name: { value: "Temporary" }))

    expect(adapter.delete("p1")).to be(true)
    expect(adapter.find("p1")).to be_nil
    expect(adapter.entries.last.operation).to eq("delete")
  end

  it "records and reloads domain events" do
    event = Hecksagain::Runtime::Event.new(
      name: "PizzaPurchased", aggregate: "Pizza", id: "p1",
      payload: { customer: "c1" }, occurred_at: "2026-01-01T00:00:00Z"
    )
    adapter.record_event(event)

    expect(adapter.events.map { |item| [item.name, item.id, item.payload] })
      .to eq([["PizzaPurchased", "p1", { customer: "c1" }]])
  end

  it "outlives the adapter that wrote it" do
    adapter.save(instance("p1", name: { value: "Margherita" }, status: "sold"))

    reopened = described_class.new(aggregate: aggregate, settings: { database: SPEC_DB })
    expect(reopened.find("p1").status).to eq("sold")
  end

  describe "query pushdown — compile fully into SQL, or refuse" do
    before do
      adapter.save(instance("p1", name: { value: "Margherita" }, price_cents: { cents: 1200 }, status: "available"))
      adapter.save(instance("p2", name: { value: "Diavola" }, price_cents: { cents: 1500 }, status: "available"))
      adapter.save(instance("p3", name: { value: "Bare" }, price_cents: { cents: 900 }, status: "sold"))
    end

    it "compiles equality on the lifecycle field" do
      declared = Hecksagain::Bluebook::DSL::AggregateBuilder.new("Pizza").tap do |builder|
        builder.query("Available") { where(status: "available") }
      end.build.queries.first

      expect(adapter.query(declared, {}).map(&:id)).to eq(%w[p1 p2])
    end

    it "compiles an ordered comparison through a value object's numeric member, with ordering and limit" do
      declared = Hecksagain::Bluebook::DSL::AggregateBuilder.new("Pizza").tap do |builder|
        builder.query("Cheap") do
          where(price_cents: { lt: 1400 })
          order_by :price_cents, :desc
          limit 5
        end
      end.build.queries.first

      expect(adapter.query(declared, {}).map(&:id)).to eq(%w[p1 p3])
    end

    it "refuses an operator it cannot compile, rather than answering from memory" do
      clause = Struct.new(:field, :op, :value).new("status", "between", "a")
      declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new([clause], nil, nil, nil, nil)

      expect { adapter.query(declared, {}) }
        .to raise_error(ArgumentError, 'Postgres query adapter does not support "between"')
    end
  end
end

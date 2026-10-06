require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../support/postgres_probe"
require_relative "../../support/era_registry_loading"

# Runs only when a Postgres server is reachable (`support/postgres_probe.rb`); manages its own
# scratch database.
RSpec.describe Hecks::Adapters::PostgresEra, :io do
  include EraRegistryLoading

  SPEC_DB = "hecks_adapter_spec".freeze

  # Stand-ins for a compiled query, its clauses and its ordering, as the adapter reads them.
  PgEraQuery = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics)
  PgEraClause = Struct.new(:field, :op, :value)
  PgEraOrder = Struct.new(:field, :direction)

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

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
    boot_in_memory.registry.bluebook("Pizzas").aggregate("Order")
  end

  let(:adapter) do
    described_class.new(aggregate: aggregate, settings: { database: SPEC_DB })
  end

  def instance(id, **fields)
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecks::Runtime::Value.for(aggregate, name, value) }
    built
  end

  def with_db(&)
    db = PG.connect(dbname: SPEC_DB)
    yield db
  ensure
    db&.close
  end

  def public_tables
    with_db { |db| db.exec("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map { |row| row["tablename"] } }
  end

  def declared_query(clauses, order: nil, limit: nil, offset: nil)
    PgEraQuery.new(clauses, order && PgEraOrder.new(*order), limit, offset, nil)
  end

  def declared_where(field, operator, value, **)
    declared_query([PgEraClause.new(field, operator, value)], **)
  end

  def margherita
    instance("p1", name: { value: "Margherita" },
                   pizza: { price_cents: { cents: 1200 }, size: { value: "small" } }, status: "available")
  end

  def pizza_purchased(id, customer, at)
    Hecks::Runtime::Event.new(name: "PizzaPurchased", aggregate: "Pizza", id: id,
                              payload: { customer: customer }, occurred_at: at)
  end

  def event_summary(events) = events.map { |item| [item.name, item.id, item.payload] }

  it "declares :atomic_append — append already commits the snapshot inside its own transaction" do
    expect(adapter.persistence_capabilities).to include(:atomic_append)
  end

  it "refuses a binding that declares no database" do
    expect { described_class.new(aggregate: aggregate, settings: {}) }
      .to raise_error(Hecks::Runtime::WiringError, /declares no "database"/)
  end

  it "refuses loudly when the declared database is unreachable" do
    expect { described_class.new(aggregate: aggregate, settings: { database: "postgres://localhost:1/nowhere" }) }
      .to raise_error(Hecks::Runtime::WiringError, %r{cannot bind PostgresEra at postgres://localhost:1/nowhere for Order})
  end

  it "saves and finds one back through the jsonb head", :aggregate_failures do
    adapter.save(margherita)

    found = adapter.find("p1")
    expect(found.name.to_h).to eq(value: "Margherita")
    expect(found.pizza.to_h).to eq(price_cents: { cents: 1200 }, size: { value: "small" })
    expect(found.status).to eq("available")
  end

  it "round-trips a list of value objects through jsonb", :aggregate_failures do
    adapter.save(instance("p1", toppings: [{ name: "Basil", amount: 3 }]))

    toppings = adapter.find("p1").toppings
    expect(toppings).to all(be_a(Hecks::Runtime::Value))
    expect(toppings.map(&:to_h)).to eq([{ name: "Basil", amount: 3 }])
  end

  # The factory merges `era: nil` for a domain the boot gate has not resolved; `setting` must
  # fall back to `@lineage.current_era`, or a fresh domain's first boot mints at era 0.
  it "resolves era 1 (not nil, not 0) when settings carry an explicit era: nil, the RepositoryFactory#build shape",
     :aggregate_failures do
    described_class.new(aggregate: aggregate, settings: { database: SPEC_DB, era: nil })

    tables = public_tables

    # Domain-qualified (ADR 0059); defaults to the owning chapter, "Pizzas".
    expect(tables).to include("pizzas_order_head_snapshot_1")
    expect(tables).not_to include("pizzas_order_head_snapshot_0", "pizzas_order_head_snapshot_")
  end

  def boot_capturing(errors)
    described_class.new(aggregate: aggregate, settings: { database: SPEC_DB })
  rescue StandardError => e
    errors << e
  end

  # Boots the domain from ten threads at once, each on its own connection; answers what raised.
  def concurrent_boot_errors
    errors = []
    Array.new(10) { Thread.new { boot_capturing(errors) } }.each(&:join)
    errors
  end

  # `ensure_base!` runs on every boot; concurrent reissue of its unguarded statements would
  # raise `tuple concurrently updated`. Uses real threads, each on its own connection.
  it "boots the same already-provisioned domain from many concurrent connections without a catalog race" do
    # establishes the base once
    described_class.new(aggregate: aggregate, settings: { database: SPEC_DB })

    errors = concurrent_boot_errors

    expect(errors).to be_empty, -> { "expected no boot to raise, got: #{errors.map(&:message).join("; ")}" }
  end

  it "answers nil for an id it never stored" do
    expect(adapter.find("nope")).to be_nil
  end

  it "keeps every write in the journal and reads the head from the last", :aggregate_failures do
    adapter.save(instance("p1", status: "available"))
    adapter.save(instance("p1", status: "sold"))

    expect(adapter.count).to eq(1)
    expect(adapter.find("p1").status).to eq("sold")
    expect(adapter.entries.map { |entry| entry.state[:status] }).to eq(%w[available sold])
  end

  it "lists everything it holds", :aggregate_failures do
    adapter.save(instance("p1", name: { value: "Margherita" }))
    adapter.save(instance("p2", name: { value: "Bare" }))

    expect(adapter.all.map(&:id)).to contain_exactly("p1", "p2")
    expect(adapter.count).to eq(2)
  end

  it "deletes through the append-only journal and the head", :aggregate_failures do
    adapter.save(instance("p1", name: { value: "Temporary" }))

    expect(adapter.delete("p1")).to be(true)
    expect(adapter.find("p1")).to be_nil
    expect(adapter.entries.last.operation).to eq("delete")
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

  it "outlives the adapter that wrote it" do
    adapter.save(instance("p1", name: { value: "Margherita" }, status: "sold"))

    reopened = described_class.new(aggregate: aggregate, settings: { database: SPEC_DB })
    expect(reopened.find("p1").status).to eq("sold")
  end

  describe "the optional saga-persistence capability (§2/§3/§4)" do
    it "saves a saga instance and reads it back through each_saga" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1",
                        state: "awaiting_credit", memory: { amount: 100 })

      rows = adapter.each_saga.to_a
      expect(rows).to eq([["Onboarding", "c1", "awaiting_credit", { amount: 100 }, []]])
    end

    it "upserts on a repeated save for the same (process_manager, correlation)" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "next", memory: { step: 2 })

      rows = adapter.each_saga.to_a
      expect(rows).to eq([["Onboarding", "c1", "next", { step: 2 }, []]])
    end

    it "deletes a saga instance" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.delete_saga(process_manager: "Onboarding", correlation: "c1")

      expect(adapter.each_saga.to_a).to eq([])
    end

    it "outlives the adapter that wrote it, same as an aggregate's own state" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: { a: 1 })

      reopened = described_class.new(aggregate: aggregate, settings: { database: SPEC_DB })
      expect(reopened.each_saga.to_a).to eq([["Onboarding", "c1", "start", { a: 1 }, []]])
    end

    it "isolates sagas by domain, the same column-based isolation hecks_eras uses", :aggregate_failures do
      other = described_class.new(aggregate: aggregate, settings: { database: SPEC_DB, domain: "OtherDomain" })
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      other.save_saga(process_manager: "Onboarding", correlation: "c1", state: "different", memory: {})

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "start", {}, []]])
      expect(other.each_saga.to_a).to eq([["Onboarding", "c1", "different", {}, []]])
    end
  end

  describe "the `schema` setting — shared-instance isolation" do
    before do
      admin = PG.connect(dbname: SPEC_DB)
      admin.exec("DROP SCHEMA IF EXISTS storehouse_a CASCADE")
      admin.exec("DROP SCHEMA IF EXISTS storehouse_b CASCADE")
      admin.exec("CREATE SCHEMA storehouse_a")
      admin.exec("CREATE SCHEMA storehouse_b")
      admin.close
    end

    let(:adapter_a) do
      described_class.new(aggregate: aggregate, settings: { database: SPEC_DB, schema: "storehouse_a" })
    end

    let(:adapter_b) do
      described_class.new(aggregate: aggregate, settings: { database: SPEC_DB, schema: "storehouse_b" })
    end

    def tables_in(schema)
      with_db do |probe|
        probe.exec_params("SELECT count(*) FROM information_schema.tables WHERE table_schema = $1", [schema])
             .getvalue(0, 0).to_i
      end
    end

    it "creates its tables inside the declared schema, not public", :aggregate_failures do
      adapter_a.save(instance("p1", name: { value: "Margherita" }))

      expect(tables_in("storehouse_a")).to be > 0
      expect(tables_in("public")).to eq(0)
    end

    it "keeps two schemas on the same instance from seeing each other's rows" do
      adapter_a.save(instance("p1", name: { value: "Margherita" }))
      adapter_b.save(instance("p1", name: { value: "Diavola" }))

      expect([adapter_a, adapter_b].map { |each_adapter| [each_adapter.find("p1").name.to_h, each_adapter.count] })
        .to eq([[{ value: "Margherita" }, 1], [{ value: "Diavola" }, 1]])
    end
  end

  describe "query pushdown — compile fully into SQL, or refuse" do
    def priced(id, label, cents, status)
      instance(id, name: { value: label }, pizza: { price_cents: { cents: cents }, size: { value: "small" } }, status: status)
    end

    before do
      adapter.save(margherita)
      adapter.save(priced("p2", "Diavola", 1500, "available"))
      adapter.save(priced("p3", "Bare", 900, "sold"))
    end

    it "refuses an operator it cannot compile, rather than answering from memory" do
      expect { adapter.query(declared_where("status", "between", "a"), {}) }
        .to raise_error(ArgumentError, 'PostgresEra query adapter does not support "between"')
    end

    # A field name containing a quote must not close the jsonb path literal into live SQL,
    # which would bypass a `where(secret: "public")` filter.
    it "a crafted field name cannot break out of the compiled jsonb path" do
      adapter.save(instance("secret", status: "TOPSECRET"))

      # a malformed field matches nothing
      expect(adapter.query(declared_where("x}' = '' OR $1::text = $1::text -- ", "eq", "available"), {})).to eq([])
    end

    it "a crafted field name cannot break the array-literal syntax into an error either" do
      expect(adapter.query(declared_where("status'} OR 1=1 --", "eq", "available"), {})).to eq([])
    end

    # One real adapter proves the remaining comparators compile and answer correctly.
    def where(clause_field, oper, clause_value, **)
      adapter.query(declared_where(clause_field, oper, clause_value, **), {}).map(&:id)
    end

    it "compiles gt/gte/lte through a value object's numeric member", :aggregate_failures do
      expect(where("pizza.price_cents.cents", "gt", 1200)).to eq(%w[p2])
      expect(where("pizza.price_cents.cents", "gte", 1200)).to eq(%w[p1 p2])
      expect(where("pizza.price_cents.cents", "lte", 1200)).to eq(%w[p1 p3])
    end

    # `contains` on a scalar field is a substring match, as in the in-memory interpreter
    # (see query_agreement_spec.rb's "carries a comma" case).
    it "compiles contains as a literal SQL substring match on a plain scalar field" do
      expect(where("status", "contains", "avail")).to eq(%w[p1 p2])
    end

    # `numeric_field?` inspects only the first nested segment, so a value object nested two
    # levels deep loses its numeric cast and orders as text; these cases use one level.
    describe "ordering through a value object nested exactly one level deep" do
      NUMERIC_PUSHDOWN_SOURCE = <<~BLUEBOOK.freeze
        Hecks.bluebook "NumericPushdown" do
          aggregate "Widget" do
            identified_by :sku
            attribute :sku,   Sku
            attribute :price, Price

            value_object "Sku" do
              attribute :value, String
            end

            value_object "Price" do
              attribute :cents, Integer
            end
          end
        end
      BLUEBOOK

      let(:numeric_registry) { load_registry(NUMERIC_PUSHDOWN_SOURCE) }
      let(:widget)          { numeric_registry.bluebooks.values.first.aggregate("Widget") }
      let(:numeric_adapter) { described_class.new(aggregate: widget, settings: { database: SPEC_DB, domain: "NumericPushdown" }) }

      def widget_instance(id, cents:)
        Hecks::Runtime::Instance.new(aggregate: widget, id: id,
                                     state: { sku: { value: id }, price: { cents: cents } })
      end

      before do
        numeric_adapter.save(widget_instance("w1", cents: 1200))
        numeric_adapter.save(widget_instance("w2", cents: 1500))
        numeric_adapter.save(widget_instance("w3", cents: 900))
      end

      it "compiles an ordered comparison through a value object's numeric member, with ordering and limit" do
        limit = Hecks::QuerySpecification::Common::LimitSpec.new(value: 5)
        declared = declared_where("price.cents", "lt", 1400, order: ["price.cents", :desc], limit: limit)

        expect(numeric_adapter.query(declared, {}).map(&:id)).to eq(%w[w1 w3])
      end

      it "compiles offset alongside limit" do
        offset_spec = Hecks::QuerySpecification::Common::OffsetSpec.new(value: 1)
        declared = declared_query([], order: ["price.cents", :asc], offset: offset_spec)

        expect(numeric_adapter.query(declared, {}).map(&:id)).to eq(%w[w1 w2])
      end
    end
  end

  # `reference_to` compiles to a scalar Reference<T> stored as a bare id; `where` on it must
  # not dig for a nested "value" key.
  describe "a reference_to reference field, queried through PostgresEra" do
    REFS_SOURCE = <<~BLUEBOOK.freeze
      Hecks.bluebook "Refs" do
        aggregate "Ticket" do
          identified_by :number
          attribute :number, TicketNumber
          reference_to Team
          reference_to Invoice, as: :invoices

          value_object "TicketNumber" do
            attribute :value, String
          end
        end

        aggregate "Team" do
          identified_by :name
          attribute :name, TeamName

          value_object "TeamName" do
            attribute :value, String
          end
        end

        aggregate "Invoice" do
          identified_by :reference
          attribute :reference, InvoiceReference

          value_object "InvoiceReference" do
            attribute :value, String
          end
        end
      end
    BLUEBOOK

    let(:refs_registry) { load_registry(REFS_SOURCE) }
    let(:ticket) { refs_registry.bluebooks.values.first.aggregate("Ticket") }
    let(:refs_adapter) { described_class.new(aggregate: ticket, settings: { database: SPEC_DB, domain: "Refs" }) }

    def save_ticket(id, **references)
      state = { number: { "value" => id }, **references }
      refs_adapter.save(Hecks::Runtime::Instance.new(aggregate: ticket, id: id, state: state))
    end

    def ticket_ids_where(field, value) = refs_adapter.query(declared_where(field, "eq", value), {}).map(&:id)

    it "declares a scalar reference, not a collection — the plural name is the only thing that changed", :aggregate_failures do
      expect(ticket.attribute(:team).reference?).to be(true)
      expect(ticket.attribute(:team).list?).to be(false)
    end

    it "stores the reference as a bare id" do
      save_ticket("t1", team: "team-a")

      # Domain-qualified (ADR 0059); `refs_adapter` sets domain: "Refs".
      raw = with_db { |db| JSON.parse(db.exec("SELECT state FROM refs_ticket_head WHERE id = 't1'")[0]["state"]) }
      expect(raw["team"]).to eq("team-a")
    end

    it "matches a where clause on the reference field" do
      save_ticket("t1", team: "team-a")
      save_ticket("t2", team: "team-b")

      expect(ticket_ids_where("team", "team-a")).to eq(["t1"])
    end

    # A plural-named reference is still a scalar reference, not a `list_of`.
    it "a plural-named reference_to still mints a scalar reference" do
      invoices = ticket.attribute(:invoices)

      expect([invoices.reference?, invoices.list?, invoices.type.to_s]).to eq([true, false, "Reference<Invoice>"])
    end

    it "queries a plural-named reference_to the same way" do
      save_ticket("t1", invoices: "inv-1")
      save_ticket("t2", invoices: "inv-2")

      expect(ticket_ids_where("invoices", "inv-1")).to eq(["t1"])
    end
  end
end

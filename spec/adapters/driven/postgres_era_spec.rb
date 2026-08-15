require "hecksagain"
require_relative "../../support/postgres_probe"

# Runs only when a Postgres server is reachable (any local default
# install will do). CI and pre-push provide one:
# a local instance or `docker run postgres` — this spec manages its own
# scratch database and needs no configuration at all. The reachability
# probe itself lives in support/postgres_probe.rb, shared by every
# Postgres spec — see that file for why.
RSpec.describe Hecksagain::Adapters::PostgresEra,
               io: true do
  SPEC_DB = "hecksagain_adapter_spec".freeze

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
      .to raise_error(Hecksagain::Runtime::WiringError, /cannot bind PostgresEra at postgres:\/\/localhost:1\/nowhere for Order/)
  end

  it "saves and finds one back through the jsonb head" do
    adapter.save(instance("p1", name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 } }, status: "available"))

    found = adapter.find("p1")
    expect(found.name.to_h).to eq(value: "Margherita")
    expect(found.pizza.to_h).to eq(price_cents: { cents: 1200 })
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

  describe "the optional saga-persistence capability (§2/§3/§4)" do
    it "saves a saga instance and reads it back through each_saga" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1",
                         state: "awaiting_credit", memory: { amount: 100 })

      rows = adapter.each_saga.to_a
      expect(rows).to eq([["Onboarding", "c1", "awaiting_credit", { amount: 100 }]])
    end

    it "upserts on a repeated save for the same (process_manager, correlation)" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "next", memory: { step: 2 })

      rows = adapter.each_saga.to_a
      expect(rows).to eq([["Onboarding", "c1", "next", { step: 2 }]])
    end

    it "deletes a saga instance" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.delete_saga(process_manager: "Onboarding", correlation: "c1")

      expect(adapter.each_saga.to_a).to eq([])
    end

    it "outlives the adapter that wrote it, same as an aggregate's own state" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: { a: 1 })

      reopened = described_class.new(aggregate: aggregate, settings: { database: SPEC_DB })
      expect(reopened.each_saga.to_a).to eq([["Onboarding", "c1", "start", { a: 1 }]])
    end

    it "isolates sagas by domain, the same column-based isolation hecks_eras uses" do
      other = described_class.new(aggregate: aggregate, settings: { database: SPEC_DB, domain: "OtherDomain" })
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      other.save_saga(process_manager: "Onboarding", correlation: "c1", state: "different", memory: {})

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "start", {}]])
      expect(other.each_saga.to_a).to eq([["Onboarding", "c1", "different", {}]])
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

    it "creates its tables inside the declared schema, not public" do
      adapter_a.save(instance("p1", name: { value: "Margherita" }))

      probe = PG.connect(dbname: SPEC_DB)
      in_schema = probe.exec_params(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = $1", ["storehouse_a"]
      ).getvalue(0, 0).to_i
      in_public = probe.exec_params(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'"
      ).getvalue(0, 0).to_i
      probe.close

      expect(in_schema).to be > 0
      expect(in_public).to eq(0)
    end

    it "keeps two schemas on the same instance from seeing each other's rows" do
      adapter_a.save(instance("p1", name: { value: "Margherita" }))
      adapter_b.save(instance("p1", name: { value: "Diavola" }))

      expect(adapter_a.find("p1").name.to_h).to eq(value: "Margherita")
      expect(adapter_b.find("p1").name.to_h).to eq(value: "Diavola")
      expect(adapter_a.count).to eq(1)
      expect(adapter_b.count).to eq(1)
    end
  end

  describe "query pushdown — compile fully into SQL, or refuse" do
    before do
      adapter.save(instance("p1", name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 } }, status: "available"))
      adapter.save(instance("p2", name: { value: "Diavola" }, pizza: { price_cents: { cents: 1500 } }, status: "available"))
      adapter.save(instance("p3", name: { value: "Bare" }, pizza: { price_cents: { cents: 900 } }, status: "sold"))
    end

    it "compiles equality on the lifecycle field" do
      declared = Hecksagain::Bluebook::DSL::AggregateBuilder.new("Pizza").tap do |builder|
        # seal_query_targets holds a query to fields the aggregate declares,
        # so the throwaway builder declares the lifecycle the query asks about.
        builder.lifecycle(:status, default: "available") do
          transition "Sell" => "sold", from: "available"
        end
        builder.query("Available") { where(status: "available") }
      end.build.queries.first

      expect(adapter.query(declared, {}).map(&:id)).to eq(%w[p1 p2])
    end

    it "refuses an operator it cannot compile, rather than answering from memory" do
      clause = Struct.new(:field, :op, :value).new("status", "between", "a")
      declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new([clause], nil, nil, nil, nil)

      expect { adapter.query(declared, {}) }
        .to raise_error(ArgumentError, 'PostgresEra query adapter does not support "between"')
    end

    # ADVERSARIAL, not incidental: today's only caller compiles field
    # names from the bluebook's own declared schema, but jsonb_path has
    # no way to know that, and its OLD form — a hand-rolled '{a,b}'
    # array-literal STRING with zero escaping — trusted a field name to
    # never contain a quote. It can: a crafted field name closed the
    # string early and turned the remainder into live SQL. This is not
    # a hypothetical — the exact payload below made a
    # where(secret: "public") clause return a row with a DIFFERENT
    # secret value, tautologically bypassing the filter, before
    # jsonb_path was rewritten to build the array from individually
    # escaped literals (ARRAY[...], the same technique lineage.rb's
    # path_literal already used for translation-rule paths).
    it "a crafted field name cannot break out of the compiled jsonb path" do
      adapter.save(instance("secret", status: "TOPSECRET"))

      injected_field = "x}' = '' OR $1::text = $1::text -- "
      clause = Struct.new(:field, :op, :value).new(injected_field, "eq", "available")
      declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new([clause], nil, nil, nil, nil)

      # neither an error NOR a bypass — a field this malformed simply
      # cannot match anything, which is the correct, boring outcome
      expect(adapter.query(declared, {})).to eq([])
    end

    it "a crafted field name cannot break the array-literal syntax into an error either" do
      injected_field = "status'} OR 1=1 --"
      clause = Struct.new(:field, :op, :value).new(injected_field, "eq", "available")
      declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new([clause], nil, nil, nil, nil)

      expect(adapter.query(declared, {})).to eq([])
    end

    # eq and lt were the only operators ever exercised against PostgresEra —
    # the rest of the comparator matrix was tested only against Memory
    # (spec/query_comparators_spec.rb). One real adapter should prove
    # the other five compile and answer correctly too.
    def where(clause_field, op, clause_value, order: nil, limit: nil, offset: nil)
      declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new(
        [Struct.new(:field, :op, :value).new(clause_field, op, clause_value)],
        order && Struct.new(:field, :direction).new(*order), limit, offset, nil
      )
      adapter.query(declared, {}).map(&:id)
    end

    it "compiles ne" do
      expect(where("status", "ne", "sold")).to eq(%w[p1 p2])
    end

    it "compiles gt/gte/lte through a value object's numeric member" do
      expect(where("pizza.price_cents.cents", "gt", 1200)).to eq(%w[p2])
      expect(where("pizza.price_cents.cents", "gte", 1200)).to eq(%w[p1 p2])
      expect(where("pizza.price_cents.cents", "lte", 1200)).to eq(%w[p1 p3])
    end

    # NOTE ON SEMANTICS, not just mechanics: `contains` on a plain scalar
    # field means substring everywhere now — the reference (in-memory)
    # interpreter's `contains?` (query_interpreter.rb) reads the same way,
    # having previously read `contains` as CSV/list membership even for a
    # scalar, which agreed with this SQL substring search only by
    # coincidence on a comma-free field. See
    # spec/adapters/query_agreement_spec.rb's "carries a comma" case for
    # the cross-engine proof. This test verifies only that PostgresEra's own
    # compilation (a value-object member would also need query_value's
    # hash-unwrapping to resolve a string, which it does not: it only
    # extracts a NUMERIC member and returns nil otherwise) executes
    # correctly.
    it "compiles contains as a literal SQL substring match on a plain scalar field" do
      expect(where("status", "contains", "avail")).to eq(%w[p1 p2])
    end

    it "compiles in as a SQL IN clause, same comma-separated convention as everywhere else" do
      expect(where("status", "in", "available,sold")).to eq(%w[p1 p2 p3])
      expect(where("status", "in", "sold")).to eq(%w[p3])
    end

    # Same reading as the in-memory interpreter's `members(want).include?` —
    # an empty candidate set matches nothing, not everything.
    it "an empty in-list matches no rows rather than every row" do
      expect(where("status", "in", "")).to eq([])
    end

    it "places nulls per the declared policy, not Postgres's own ASC/DESC default" do
      adapter.save(instance("p4", name: { value: "Unpurchased" }, pizza: { price_cents: { cents: 500 } }, status: "available"))
      adapter.save(instance("p1", name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 } },
                                    status: "available", customer_name: { value: "Alex" }))

      first_mode = Struct.new(:mode).new("first")
      declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new(
        [], Struct.new(:field, :direction).new("customer_name", :asc), nil, nil, first_mode
      )
      # p2/p3 never had customer_name set at all — null, and NULLS FIRST
      # puts them ahead of p1's real value regardless of Postgres's own
      # per-direction default (which would otherwise put nulls LAST on
      # ASC, disagreeing with the other adapters).
      expect(adapter.query(declared, {}).map(&:id).first(2)).to contain_exactly("p2", "p3")
      expect(adapter.query(declared, {}).map(&:id).last).to eq("p1")
    end

    # `pizza.price_cents.cents` (the live Pizzas domain's own numeric field)
    # is a value object nested TWO levels deep, and `numeric_field?`
    # (postgres_era.rb) only ever inspects the first nested segment — it was
    # never built to recurse. A dotted path that deep still compiles a
    # correct jsonb EXTRACTION (arbitrary depth), but the numeric CAST is
    # skipped, so ordering falls back to lexicographic text — wrong for any
    # values of differing digit width. Rather than growing the query
    # compiler to recurse (a real, separate change), these two cases are
    # proven here against a fixture shaped the way pushdown numeric
    # comparison actually supports today: one level of value-object nesting.
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

      let(:numeric_registry) do
        registry = Hecksagain::Runtime::Registry.new
        loading  = Hecksagain::Ports::Loading.bootstrap
        file     = Tempfile.new(["numeric-pushdown-", ".bluebook"])
        file.write(NUMERIC_PUSHDOWN_SOURCE)
        file.flush
        Hecksagain.with_registry(registry) do
          loading.load_library
          Kernel.eval(NUMERIC_PUSHDOWN_SOURCE, TOPLEVEL_BINDING, file.path, 1)
        end
        registry
      ensure
        file&.close!
      end

      let(:widget)          { numeric_registry.bluebooks.values.first.aggregate("Widget") }
      let(:numeric_adapter) { described_class.new(aggregate: widget, settings: { database: SPEC_DB, domain: "NumericPushdown" }) }

      def widget_instance(id, cents:)
        Hecksagain::Runtime::Instance.new(aggregate: widget, id: id,
                                           state: { sku: { value: id }, price: { cents: cents } })
      end

      before do
        numeric_adapter.save(widget_instance("w1", cents: 1200))
        numeric_adapter.save(widget_instance("w2", cents: 1500))
        numeric_adapter.save(widget_instance("w3", cents: 900))
      end

      it "compiles an ordered comparison through a value object's numeric member, with ordering and limit" do
        declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new(
          [Struct.new(:field, :op, :value).new("price.cents", "lt", 1400)],
          Struct.new(:field, :direction).new("price.cents", :desc),
          Hecksagain::QuerySpecification::Common::LimitSpec.new(value: 5), nil, nil
        )
        expect(numeric_adapter.query(declared, {}).map(&:id)).to eq(%w[w1 w3])
      end

      it "compiles offset alongside limit" do
        offset_spec = Hecksagain::QuerySpecification::Common::OffsetSpec.new(value: 1)
        declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new(
          [], Struct.new(:field, :direction).new("price.cents", :asc), nil, offset_spec, nil
        )
        expect(numeric_adapter.query(declared, {}).map(&:id)).to eq(%w[w1 w2])
      end
    end
  end

  # `has_one`/`belongs_to`/`has_many` (DSL sugar over reference_to — see
  # aggregate_builder.rb) all compile to a scalar Reference<T> attribute,
  # stored as a bare id (never wrapped — Runtime::Value refuses a
  # reference arriving as a hash). No fixture anywhere declared one
  # before this, and none was exercised against PostgresEra: `where` on
  # such a field compiled to `state #>> '{field,value}'`, digging for a
  # nested "value" key that a bare scalar never has, and silently
  # matched nothing. Falsified before trusting it: reverting the fix in
  # query_expression reproduces the empty result exactly.
  describe "a has_one/belongs_to reference field, queried through PostgresEra" do
    REFS_SOURCE = <<~BLUEBOOK.freeze
      Hecks.bluebook "Refs" do
        aggregate "Ticket" do
          identified_by :number
          attribute :number, TicketNumber
          belongs_to :Team
          has_many :Invoices

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

    let(:refs_registry) do
      registry = Hecksagain::Runtime::Registry.new
      loading = Hecksagain::Ports::Loading.bootstrap
      file = Tempfile.new(["refs-", ".bluebook"])
      file.write(REFS_SOURCE)
      file.flush
      Hecksagain.with_registry(registry) do
        loading.load_library
        Kernel.eval(REFS_SOURCE, TOPLEVEL_BINDING, file.path, 1)
      end
      registry
    ensure
      file&.close!
    end

    let(:ticket) { refs_registry.bluebooks.values.first.aggregate("Ticket") }
    let(:refs_adapter) { described_class.new(aggregate: ticket, settings: { database: SPEC_DB, domain: "Refs" }) }

    it "declares a scalar reference, not a collection — the plural name is the only thing that changed" do
      expect(ticket.attribute(:team).reference?).to be(true)
      expect(ticket.attribute(:team).list?).to be(false)
    end

    it "stores the reference as a bare id" do
      refs_adapter.save(Hecksagain::Runtime::Instance.new(
        aggregate: ticket, id: "t1", state: { number: { "value" => "t1" }, team: "team-a" }
      ))

      db = PG.connect(dbname: SPEC_DB)
      raw = JSON.parse(db.exec("SELECT state FROM ticket_head WHERE id = 't1'")[0]["state"])
      db.close
      expect(raw["team"]).to eq("team-a")
    end

    it "matches a where clause on the reference field" do
      refs_adapter.save(Hecksagain::Runtime::Instance.new(
        aggregate: ticket, id: "t1", state: { number: { "value" => "t1" }, team: "team-a" }
      ))
      refs_adapter.save(Hecksagain::Runtime::Instance.new(
        aggregate: ticket, id: "t2", state: { number: { "value" => "t2" }, team: "team-b" }
      ))

      declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new(
        [Struct.new(:field, :op, :value).new("team", "eq", "team-a")], nil, nil, nil, nil
      )
      expect(refs_adapter.query(declared, {}).map(&:id)).to eq(["t1"])
    end

    # has_many's own naming logic (demodulise + singularize, distinct DSL
    # code from has_one/belongs_to) is what most invites the "list_of a
    # reference" misreading the name suggests — proven wrong at the DSL
    # level already (aggregate_builder.rb), but never before against a
    # real save/query round trip through any adapter.
    it "has_many :Invoices singularizes to a scalar invoices reference, queryable the same way" do
      expect(ticket.attribute(:invoices).reference?).to be(true)
      expect(ticket.attribute(:invoices).list?).to be(false)
      expect(ticket.attribute(:invoices).type.to_s).to eq("Reference<Invoice>")

      refs_adapter.save(Hecksagain::Runtime::Instance.new(
        aggregate: ticket, id: "t1", state: { number: { "value" => "t1" }, invoices: "inv-1" }
      ))
      refs_adapter.save(Hecksagain::Runtime::Instance.new(
        aggregate: ticket, id: "t2", state: { number: { "value" => "t2" }, invoices: "inv-2" }
      ))

      declared = Struct.new(:wheres, :order_by, :limit, :offset, :null_semantics).new(
        [Struct.new(:field, :op, :value).new("invoices", "eq", "inv-1")], nil, nil, nil, nil
      )
      expect(refs_adapter.query(declared, {}).map(&:id)).to eq(["t1"])
    end
  end
end

require "hecksagain"
require "tmpdir"
# `pg` is required explicitly — the adapter only requires it lazily,
# inside `Postgres.connect_for` — see postgres_spec.rb's own note.
require "pg"

# WHY THIS GATE EXISTS: every existing adapter spec (postgres_spec.rb,
# sqlite_spec.rb, memory-backed specs elsewhere) proves each adapter
# self-consistent — it asks the adapter a question and checks the
# adapter's OWN answer looks sane. None of them ever checked that Memory,
# Sqlite, and Postgres AGREE WITH EACH OTHER on the same declared query
# over the same records. A self-referential oracle cannot see divergence
# — that is exactly why nested-field query bugs (numeric_field? judging
# only the first path segment, a dotted field silently matching nothing
# in the reference interpreter) shipped silently: nothing ever put two
# engines' answers side by side. This file is that differential gate,
# reborn adapter-vs-adapter instead of Ruby-vs-Rust.
#
# Every case below asserts against a HAND-COMPUTED expected id list —
# not merely "the three adapters agree with each other" — because three
# engines sharing one bug would still "agree" under a pairwise check. The
# expectation is an independent oracle, worked out by hand from the
# fixture table, and cross-adapter agreement follows transitively from
# every engine matching it.
postgres_available =
  begin
    PG.connect(dbname: "postgres").close
    true
  rescue PG::Error
    false
  end

RSpec.describe "adapter agreement — declared queries answer identically across Memory, Sqlite, and Postgres" do
  AGREEMENT_DB = "hecksagain_query_agreement_spec".freeze
  # A def sees no file-local the way the hook blocks do — the probe's
  # verdict crosses into agree! as a constant.
  POSTGRES_AVAILABLE = postgres_available

  before(:all) do
    next unless postgres_available

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{AGREEMENT_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{AGREEMENT_DB}")
    admin.close
  end

  after(:all) do
    next unless postgres_available

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{AGREEMENT_DB} WITH (FORCE)")
    admin.close
  end

  before do
    next unless postgres_available

    scrub = PG.connect(dbname: AGREEMENT_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  around do |example|
    @dir = Dir.mktmpdir("hecksagain-query-agreement-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  # ONE aggregate carries every field the 11 cases below ask about, and
  # every query is declared THROUGH the builder so seal_query_targets
  # blesses each one (a query over an undeclared field, a dotted path
  # that lands on a value object instead of a scalar, or an ordered
  # comparator over a non-numeric field all refuse at build time — this
  # fixture exercises none of those refusals, only the answering side).
  def build_aggregate
    Hecksagain::Bluebook::DSL::AggregateBuilder.new("Thing").tap do |builder|
      builder.lifecycle(:status, default: "open") do
        transition "Close" => "closed", from: "open"
      end

      builder.value_object("Money") { attribute :cents, Integer }
      builder.value_object("Name")  { attribute :value, String }
      builder.value_object("Price") { attribute :cents, Integer }
      builder.value_object("Box")   { attribute :price, "Price" }
      builder.value_object("Tag")   { attribute :name, String }
      builder.value_object("Note")  { attribute :value, String }

      builder.attribute :name,    "Name"
      builder.attribute :balance, "Money"
      builder.attribute :box,     "Box"
      builder.attribute :tags,    builder.list_of("Tag")
      builder.attribute :note,    "Note"

      builder.query("OpenOnes")       { where(status: "open") }
      builder.query("NotClosed")      { where(status: { ne: "closed" }) }
      builder.query("InBothStatuses") { where(status: { in: "open,closed" }) }
      # An empty in-list is not refused at the seal — only lt/lte/gt/gte
      # get the numeric-field check — so this stays admitted, and every
      # engine's own documented reading is "empty candidate set matches
      # no rows" (Ports::Query::InMemory#members("") splits to [], SQL's
      # empty_in_clause compiles to a literal falsehood).
      builder.query("InNoStatuses") { where(status: { in: "" }) }

      builder.query("BelowFloor") do
        attribute :floor, "Money"
        where(balance: { lt: :floor })
        order_by :balance
      end

      builder.query("AtLeast500Desc") do
        where(balance: { gte: { cents: 500 } })
        order_by :balance, :desc
      end

      builder.query("PriceAbove300") do
        where(:"box.price.cents" => { gt: 300 })
        order_by :"box.price.cents"
        limit 2
      end

      builder.query("PriceAscOffset") do
        order_by :"box.price.cents"
        offset 1
      end

      builder.query("ByNameAsc") { order_by :name }

      builder.query("TaggedRed") { where(tags: { contains: "red" }) }

      builder.query("StatusContainsOpen") { where(status: { contains: "open" }) }

      # The comma-bearing case — `note.value` genuinely carries a comma as
      # PART OF ITS OWN CONTENT, not as a separator. `contains` on a
      # scalar field means substring on every engine (Ports::Query::
      # InMemory#contains?, QueryInterpreter#contains?,
      # SqlQueryBuilder#contains_clause) — this exact case used to expose
      # a divergence, back when the reference interpreter read `contains`
      # as CSV-split membership and would have split this note in two.
      builder.query("NoteContainsPhrase") { where(note: { contains: "high, risk" }) }
    end.build
  end

  let(:aggregate) { build_aggregate }

  let(:memory)   { Hecksagain::Adapters::Memory.new(aggregate: aggregate) }
  let(:sqlite)   { Hecksagain::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "agreement.db" }, root: @dir) }
  let(:postgres) { postgres_available ? Hecksagain::Adapters::Postgres.new(aggregate: aggregate, settings: { database: AGREEMENT_DB }) : nil }

  def instance(id, **fields)
    built = Hecksagain::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecksagain::Runtime::Value.for(aggregate, name, value) }
    built
  end

  # Five records, distinct on every axis a case below probes. `name` is
  # deliberately NOT alphabetical in id order — ByNameAsc must actually
  # sort by the declared field, or a bug that quietly falls back to
  # identity order would pass unnoticed.
  # `note` deliberately puts a comma in a place that would have broken
  # the old CSV-split reading of `contains`: r1 and r4 carry the exact
  # phrase "high, risk" ; r2 carries a comma elsewhere in text that still
  # contains both words separately (a false positive the old membership
  # reading could not have produced, but a real regression test for
  # substring reading getting it right either way).
  RECORDS = {
    "r1" => { status: "open",   balance: { cents: 100 }, box: { price: { cents: 100 } }, name: { value: "Eve" },   tags: [{ name: "red" }],   note: { value: "flagged: high, risk today" } },
    "r2" => { status: "open",   balance: { cents: 500 }, box: { price: { cents: 500 } }, name: { value: "Carol" }, tags: [{ name: "blue" }],  note: { value: "high risk, but flagged separately" } },
    "r3" => { status: "closed", balance: { cents: 900 }, box: { price: { cents: 900 } }, name: { value: "Alice" }, tags: [{ name: "green" }], note: { value: "nothing unusual" } },
    "r4" => { status: "closed", balance: { cents: 300 }, box: { price: { cents: 300 } }, name: { value: "Dave" },  tags: [{ name: "red" }],   note: { value: "high, risk, reviewed" } },
    "r5" => { status: "open",   balance: { cents: 700 }, box: { price: { cents: 700 } }, name: { value: "Bob" },   tags: [{ name: "blue" }],  note: { value: "low risk" } }
  }.freeze

  before do
    RECORDS.each do |id, fields|
      memory.save(instance(id, **fields))
      sqlite.save(instance(id, **fields))
      postgres&.save(instance(id, **fields))
    end
  end

  # Runs the named declared query against every adapter under test and
  # checks each against the SAME hand-computed `expected` — the
  # independent oracle. Postgres participates only when reachable, so
  # Memory-vs-Sqlite agreement still runs (and still means something) on
  # a machine with no local Postgres.
  def agree!(query_name, args = {}, expected:)
    declared = aggregate.query(query_name)

    expect(memory.query(declared, args).map(&:id)).to eq(expected)
    expect(sqlite.query(declared, args).map(&:id)).to eq(expected)
    expect(postgres.query(declared, args).map(&:id)).to eq(expected) if POSTGRES_AVAILABLE
  end

  it "compiles eq on the lifecycle field the same everywhere" do
    agree!("OpenOnes", expected: %w[r1 r2 r5])
  end

  it "compiles ne on the lifecycle field the same everywhere" do
    agree!("NotClosed", expected: %w[r1 r2 r5])
  end

  it "compiles in on the lifecycle field, matching every listed value, the same everywhere" do
    agree!("InBothStatuses", expected: %w[r1 r2 r3 r4 r5])
  end

  it "compiles an empty in-list as matching nothing, the same everywhere" do
    agree!("InNoStatuses", expected: [])
  end

  it "compiles lt through a :symbol query argument on a bare value object, ordered, the same everywhere" do
    agree!("BelowFloor", { floor: { cents: 500 } }, expected: %w[r1 r4])
  end

  it "compiles gte with a literal value on a bare value object, descending, the same everywhere" do
    agree!("AtLeast500Desc", expected: %w[r3 r5 r2])
  end

  it "compiles gt on a two-level nested path, ordered and limited, the same everywhere" do
    agree!("PriceAbove300", expected: %w[r2 r5])
  end

  it "orders by a two-level nested path ascending, with an offset, the same everywhere" do
    agree!("PriceAscOffset", expected: %w[r4 r2 r5 r3])
  end

  it "orders by a string value object ascending, the same everywhere" do
    agree!("ByNameAsc", expected: %w[r3 r5 r2 r4 r1])
  end

  it "compiles contains on a list of value objects, matching by member name, the same everywhere" do
    agree!("TaggedRed", expected: %w[r1 r4])
  end

  it "compiles contains on the lifecycle field for a comma-free, whole-value match, the same everywhere" do
    agree!("StatusContainsOpen", expected: %w[r1 r2 r5])
  end

  it "compiles contains as a real substring on a scalar field whose own content carries a comma, the same everywhere" do
    agree!("NoteContainsPhrase", expected: %w[r1 r4])
  end
end

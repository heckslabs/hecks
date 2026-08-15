require "hecksagain"
require "tmpdir"
require_relative "../support/postgres_probe"
# `pg` is required explicitly — the adapter only requires it lazily,
# inside `PostgresEra.connect_for` — see postgres_era_spec.rb's own note.
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
# The reachability probe itself lives in support/postgres_probe.rb,
# shared by every Postgres spec — a real `PG.connect` round trip asking
# the identical question five separate times over was real, redundant
# I/O. LAZY: `postgres_available?` below only calls it from inside a
# hook/example body, never at file-load time — see postgres_probe.rb's
# own header for why that distinction matters even under `io: true`.

# D1 needs real Cloudflare credentials (CLOUDFLARE_ACCOUNT_ID,
# CLOUDFLARE_D1_DATABASE_ID, CLOUDFLARE_D1_API_TOKEN) — optional, same as
# Postgres above: this gate runs Memory-vs-Sqlite-vs-Postgres agreement on
# any machine, and additionally includes D1 wherever those three env vars
# point at a real, reachable database. Same laziness as Postgres: only a
# module method, memoized once, never a top-level constant — module
# DEFINITION does no I/O, only calling `.available?` does.
module QueryAgreementD1Probe
  def self.available?
    return @available if defined?(@available)

    @available =
      begin
        if ENV["CLOUDFLARE_ACCOUNT_ID"] && ENV["CLOUDFLARE_D1_DATABASE_ID"] && ENV["CLOUDFLARE_D1_API_TOKEN"]
          Hecksagain::Adapters::D1::Connection.new(
            account_id:  ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
            database_id: ENV.fetch("CLOUDFLARE_D1_DATABASE_ID"),
            api_token:   ENV.fetch("CLOUDFLARE_D1_API_TOKEN")
          ).execute("SELECT 1")
          true
        else
          false
        end
      rescue StandardError
        false
      end
  end
end

RSpec.describe "adapter agreement — declared queries answer identically across Memory, Sqlite, Postgres, and D1",
               io: true do
  AGREEMENT_DB = "hecksagain_query_agreement_spec".freeze

  # Instance methods, not `def self.` — `PostgresProbe`/`QueryAgreementD1Probe`
  # already memoize the real check once at the module level, so every call
  # below is cheap; these just give hook/example bodies a short name for it.
  def postgres_available? = PostgresProbe.available?
  def d1_available? = QueryAgreementD1Probe.available?

  before(:all) do
    next unless postgres_available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{AGREEMENT_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{AGREEMENT_DB}")
    admin.close
  end

  after(:all) do
    next unless postgres_available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{AGREEMENT_DB} WITH (FORCE)")
    admin.close
  end

  before do
    next unless postgres_available?

    scrub = PG.connect(dbname: AGREEMENT_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  # D1 has no throwaway-database-per-run the way Postgres does here (one
  # real, persistent database was provisioned for this, not minted and
  # dropped per suite run) — so instead of DROP SCHEMA/CREATE SCHEMA, this
  # drops just the two tables the "Thing" fixture actually uses, which
  # gets to the same state: empty tables, freshly recreated by whichever
  # adapter's own schema-creation runs next when `d1` is first touched.
  before do
    next unless d1_available?

    scrub = Hecksagain::Adapters::D1::Connection.new(
      account_id:  ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
      database_id: ENV.fetch("CLOUDFLARE_D1_DATABASE_ID"),
      api_token:   ENV.fetch("CLOUDFLARE_D1_API_TOKEN")
    )
    scrub.execute("DROP TABLE IF EXISTS thing")
    scrub.execute("DROP TABLE IF EXISTS thing_entries")
    scrub.execute("DROP TABLE IF EXISTS events")
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
  # `ConstShim.with` — this fixture calls the builder API directly
  # (`Hecksagain::Bluebook::DSL::AggregateBuilder.new(...).tap { |b| ... }`),
  # outside any `Hecks.bluebook do ... end`/`instance_eval` a real bluebook
  # loads through, so `Object.const_missing`'s own global hook (S0b) is
  # never installed unless this does it directly — without it, a bare
  # `Money`/`Name`/... below would raise `NameError`, not resolve the
  # forward reference the way it would inside a real bluebook. The
  # resolver just hands the const back (`bluebook_builder.rb`'s own
  # bareword resolver) — `Attribute#spell`'s `type.to_s` renders a Symbol
  # identically to the quoted String this replaces.
  def build_aggregate
    Hecksagain::Bluebook::DSL::ConstShim.with(->(const) { const }) { build_thing_aggregate }
  end

  def build_thing_aggregate
    Hecksagain::Bluebook::DSL::AggregateBuilder.new("Thing").tap do |builder|
      builder.lifecycle(:status, default: "open") do
        transition "Close" => "closed", from: "open"
      end

      builder.value_object("Money") { attribute :cents, Integer }
      builder.value_object("Name")  { attribute :value, String }
      builder.value_object("Price") { attribute :cents, Integer }
      builder.value_object("Box")   { attribute :price, Price }
      builder.value_object("Tag")   { attribute :name, String }
      builder.value_object("Note")  { attribute :value, String }
      # THE NULLABLE AXIS. Every field above is present on every record,
      # so until these two existed no case here could exercise a null at
      # all — which is how three separate null bugs reached main through
      # this gate (`ne:` with an empty string, array `in:`, and `ne:`
      # against a null field, where Memory returned a row every SQL
      # engine omitted because Ruby's `nil != "x"` is true and SQL's
      # `NULL <> 'x'` is NULL).
      builder.value_object("Rating") { attribute :value, Integer }
      builder.value_object("Label")  { attribute :value, String }

      builder.attribute :name,    Name
      builder.attribute :balance, Money
      builder.attribute :box,     Box
      builder.attribute :tags,    builder.list_of(Tag)
      builder.attribute :note,    Note
      builder.attribute :rating,  Rating, optional: true
      builder.attribute :label,   Label,  optional: true

      builder.query("OpenOnes")       { where(status: "open") }
      builder.query("NotClosed")      { where(status: { ne: "closed" }) }
      builder.query("InBothStatuses") { where(status: { in: "open,closed" }) }
      # A REAL ARRAY, not a comma-joined string — and every member is a
      # whole sentence that carries its own commas as CONTENT, the exact
      # shape an id built from a joined identity path could take. Under
      # the old `value.to_s.split(",")` reading this matched nothing at
      # all on Sqlite/Postgres (the array's own `.to_s` gets re-split on
      # every comma inside it, member and content alike) while Memory
      # already read a real Array correctly — a divergence, not a typo.
      builder.query("NoteValuesIn") do
        where(:"note.value" => { in: ["flagged: high, risk today", "high, risk, reviewed"] })
      end
      # An empty in-list is not refused at the seal — only lt/lte/gt/gte
      # get the numeric-field check — so this stays admitted, and every
      # engine's own documented reading is "empty candidate set matches
      # no rows" (Ports::Query::InMemory#members("") splits to [], SQL's
      # empty_in_clause compiles to a literal falsehood).
      builder.query("InNoStatuses") { where(status: { in: "" }) }

      builder.query("BelowFloor") do
        attribute :floor, Money
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

      # A NULL SATISFIES NO COMPARISON — one case per comparator, because
      # the engines had every opportunity to disagree per-operator and
      # `ne` is simply the one somebody happened to write in a bluebook.
      builder.query("LabelNotBeta")    { where(:"label.value"  => { ne: "beta" }) }
      builder.query("LabelIsAlpha")    { where(:"label.value"  => "alpha") }
      builder.query("RatingAbove200")  { where(:"rating.value" => { gt: 200 }) }
      builder.query("RatingBelow400")  { where(:"rating.value" => { lt: 400 }) }
      builder.query("RatingInList")    { where(:"rating.value" => { in: "100,300" }) }
      builder.query("LabelContainsPh") { where(:"label.value"  => { contains: "ph" }) }

      # THE OTHER HALF, and the one already agreed before this: a null on
      # the value COMPARED TO is a deliberate IS NULL / IS NOT NULL, not
      # an unknown (NullPolicy.sql_predicate). Included so the two
      # readings are pinned against each other — if either drifts toward
      # the other, one of these two fails.
      builder.query("LabelIsNull")    { where(:"label.value" => nil) }
      builder.query("LabelIsNotNull") { where(:"label.value" => { ne: nil }) }

      # ORDERING is NullPolicy's other half again, and carries the same
      # two-implementation risk the comparators did — `order` in Ruby and
      # `sql_order` in SQL, agreeing only by construction.
      builder.query("ByRatingNullsFirst") do
        order_by :"rating.value"
        nulls :first
      end
      builder.query("ByRatingNullsLast") do
        order_by :"rating.value"
        nulls :last
      end
    end.build
  end

  let(:aggregate) { build_aggregate }

  let(:memory)   { Hecksagain::Adapters::Memory.new(aggregate: aggregate) }
  let(:sqlite)   { Hecksagain::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "agreement.db" }, root: @dir) }
  let(:postgres) { postgres_available? ? Hecksagain::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: AGREEMENT_DB }) : nil }
  let(:d1) do
    next nil unless d1_available?

    Hecksagain::Adapters::D1.new(
      aggregate: aggregate,
      settings: {
        account_id:  ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
        database_id: ENV.fetch("CLOUDFLARE_D1_DATABASE_ID"),
        api_token:   ENV.fetch("CLOUDFLARE_D1_API_TOKEN")
      }
    )
  end

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
  # `rating` and `label` are ABSENT on r2 and r4 — the nullable axis. Two
  # nulls rather than one, and on the same two records for both fields,
  # so a case cannot pass by accident on a single-row coincidence, and
  # ordering has a real tie to break among the nulls.
  RECORDS = {
    "r1" => { status: "open",   balance: { cents: 100 }, box: { price: { cents: 100 } }, name: { value: "Eve" },   tags: [{ name: "red" }],   note: { value: "flagged: high, risk today" },      rating: { value: 100 }, label: { value: "alpha" } },
    "r2" => { status: "open",   balance: { cents: 500 }, box: { price: { cents: 500 } }, name: { value: "Carol" }, tags: [{ name: "blue" }],  note: { value: "high risk, but flagged separately" } },
    "r3" => { status: "closed", balance: { cents: 900 }, box: { price: { cents: 900 } }, name: { value: "Alice" }, tags: [{ name: "green" }], note: { value: "nothing unusual" },               rating: { value: 300 }, label: { value: "beta" } },
    "r4" => { status: "closed", balance: { cents: 300 }, box: { price: { cents: 300 } }, name: { value: "Dave" },  tags: [{ name: "red" }],   note: { value: "high, risk, reviewed" } },
    "r5" => { status: "open",   balance: { cents: 700 }, box: { price: { cents: 700 } }, name: { value: "Bob" },   tags: [{ name: "blue" }],  note: { value: "low risk" },                       rating: { value: 500 }, label: { value: "phase" } }
  }.freeze

  before do
    RECORDS.each do |id, fields|
      memory.save(instance(id, **fields))
      sqlite.save(instance(id, **fields))
      postgres&.save(instance(id, **fields))
      d1&.save(instance(id, **fields))
    end
  end

  # Runs the named declared query against every adapter under test and
  # checks each against the SAME hand-computed `expected` — the
  # independent oracle. Postgres and D1 participate only when reachable, so
  # Memory-vs-Sqlite agreement still runs (and still means something) on
  # a machine with no local Postgres.
  def agree!(query_name, args = {}, expected:)
    declared = aggregate.query(query_name)

    expect(memory.query(declared, args).map(&:id)).to eq(expected)
    expect(sqlite.query(declared, args).map(&:id)).to eq(expected)
    expect(postgres.query(declared, args).map(&:id)).to eq(expected) if postgres_available?
    expect(d1.query(declared, args).map(&:id)).to eq(expected) if d1_available?
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

  it "compiles in on a real Array whose own members carry commas, the same everywhere" do
    agree!("NoteValuesIn", expected: %w[r1 r4])
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

  # r2 and r4 hold no rating and no label. Every case below asserts they
  # are ABSENT from the answer — a null is unknown, and unknown satisfies
  # no comparison. Memory used to return them for `ne` while every SQL
  # engine omitted them.
  it "excludes nulls from ne, the same everywhere" do
    agree!("LabelNotBeta", expected: %w[r1 r5])
  end

  it "excludes nulls from eq, the same everywhere" do
    agree!("LabelIsAlpha", expected: %w[r1])
  end

  it "excludes nulls from gt, the same everywhere" do
    agree!("RatingAbove200", expected: %w[r3 r5])
  end

  it "excludes nulls from lt, the same everywhere" do
    agree!("RatingBelow400", expected: %w[r1 r3])
  end

  it "excludes nulls from in, the same everywhere" do
    agree!("RatingInList", expected: %w[r1 r3])
  end

  it "excludes nulls from contains, the same everywhere" do
    agree!("LabelContainsPh", expected: %w[r1 r5])
  end

  # The deliberate null, as opposed to the unknown one: comparing TO nil
  # is a real question about presence, and both engines already answered
  # it the same way. Pinned here so neither reading drifts into the other.
  it "reads a comparison to nil as IS NULL, the same everywhere" do
    agree!("LabelIsNull", expected: %w[r2 r4])
  end

  it "reads ne nil as IS NOT NULL, the same everywhere" do
    agree!("LabelIsNotNull", expected: %w[r1 r3 r5])
  end

  it "places nulls first when asked, the same everywhere" do
    agree!("ByRatingNullsFirst", expected: %w[r2 r4 r1 r3 r5])
  end

  it "places nulls last when asked, the same everywhere" do
    agree!("ByRatingNullsLast", expected: %w[r1 r3 r5 r2 r4])
  end
end

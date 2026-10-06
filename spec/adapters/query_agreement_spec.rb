require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"
require_relative "../support/postgres_probe"
# `pg` is required explicitly; the adapter only requires it lazily in `PostgresEra.connect_for`.
require "pg"

# Differential gate: Memory, Sqlite and Postgres must agree on the same declared query over the
# same records. Every case also asserts a hand-computed id list, since engines sharing one bug
# would still agree pairwise.
# The reachability probe (support/postgres_probe.rb) is lazy: called only from hooks and
# examples, never at file-load time.

# D1 joins the run only when CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_D1_DATABASE_ID and
# CLOUDFLARE_D1_API_TOKEN point at a reachable database; probed lazily, like Postgres.
module QueryAgreementD1Probe
  def self.available?
    return @available if defined?(@available)

    @available = configured? && reachable?
  end

  def self.configured?
    %w[CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_D1_DATABASE_ID CLOUDFLARE_D1_API_TOKEN].all? { |name| ENV.fetch(name, nil) }
  end

  # The connection settings the three variables spell.
  def self.settings
    {
      account_id:  ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
      database_id: ENV.fetch("CLOUDFLARE_D1_DATABASE_ID"),
      api_token:   ENV.fetch("CLOUDFLARE_D1_API_TOKEN")
    }
  end

  def self.reachable?
    Hecks::Adapters::D1::Connection.new(**settings).execute("SELECT 1")
    true
  rescue StandardError
    false
  end
end

RSpec.describe "adapter agreement — declared queries answer identically across Memory, Sqlite, " \
               "PostgresEra, plain Postgres, and D1",
               :io do
  # Named for the process, so two runs on one Postgres (parallel sessions) never drop each
  # other's databases mid-spec.
  AGREEMENT_DB = "hecks_query_agreement_spec_#{Process.pid}".freeze
  # Separate from AGREEMENT_DB: one database per engine keeps `DROP SCHEMA public CASCADE`
  # on one from touching the other's tables.
  PLAIN_POSTGRES_AGREEMENT_DB = "#{AGREEMENT_DB}_plain".freeze

  # Instance methods over the module-level memoized probes, giving hooks a short name.
  def postgres_available? = PostgresProbe.available?
  def d1_available? = QueryAgreementD1Probe.available?

  before(:all) do
    next unless postgres_available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{AGREEMENT_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{AGREEMENT_DB}")
    admin.exec("DROP DATABASE IF EXISTS #{PLAIN_POSTGRES_AGREEMENT_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{PLAIN_POSTGRES_AGREEMENT_DB}")
    admin.close
  end

  after(:all) do
    next unless postgres_available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{AGREEMENT_DB} WITH (FORCE)")
    admin.exec("DROP DATABASE IF EXISTS #{PLAIN_POSTGRES_AGREEMENT_DB} WITH (FORCE)")
    admin.close
  end

  def scrub_postgres_databases
    return unless postgres_available?

    [AGREEMENT_DB, PLAIN_POSTGRES_AGREEMENT_DB].each do |database|
      scrub = PG.connect(dbname: database)
      scrub.exec("DROP SCHEMA public CASCADE")
      scrub.exec("CREATE SCHEMA public")
      scrub.close
    end
  end

  # D1 is one persistent database, so reset drops just the "Thing" tables, not the schema.
  def scrub_d1_tables
    return unless d1_available?

    scrub = Hecks::Adapters::D1::Connection.new(**QueryAgreementD1Probe.settings)
    %w[thing thing_entries events].each { |table| scrub.execute("DROP TABLE IF EXISTS #{table}") }
  end

  around do |example|
    @dir = Dir.mktmpdir("hecks-query-agreement-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  # One aggregate carries every field the cases ask about; queries go through the builder so
  # seal_query_targets blesses each one.
  # `ConstShim.with`: the builder API is called outside a bluebook load, so the global
  # const_missing hook is not installed and a bare `Money`/`Name` would raise NameError.
  def build_aggregate
    Hecks::Bluebook::DSL::ConstShim.with(->(const) { const }) { build_thing_aggregate }
  end

  def build_thing_aggregate
    Hecks::Bluebook::DSL::AggregateBuilder.new("Thing").tap do |builder|
      declare_thing_shape(builder)
      declare_status_queries(builder)
      declare_ordered_queries(builder)
      declare_nested_path_queries(builder)
      declare_contains_queries(builder)
      declare_null_queries(builder)
    end.build
  end

  def declare_thing_shape(builder)
    builder.lifecycle(:status, default: "open") do
      transition "Close" => "closed", from: "open"
    end
    declare_value_objects(builder)
    declare_attributes(builder)
  end

  def declare_value_objects(builder)
    builder.value_object("Money") { attribute :cents, Integer }
    builder.value_object("Name")  { attribute :value, String }
    builder.value_object("Price") { attribute :cents, Integer }
    builder.value_object("Box")   { attribute :price, Price }
    builder.value_object("Tag")   { attribute :name, String }
    builder.value_object("Note")  { attribute :value, String }
    # The nullable axis: `ne:` against a null field matches on Memory (`nil != "x"`) but not
    # in SQL (`NULL <> 'x'` is NULL).
    builder.value_object("Rating") { attribute :value, Integer }
    builder.value_object("Label")  { attribute :value, String }
  end

  def declare_attributes(builder)
    builder.attribute :name,    Name
    builder.attribute :balance, Money
    builder.attribute :box,     Box
    builder.attribute :tags,    builder.list_of(Tag)
    builder.attribute :note,    Note
    builder.attribute :rating,  Rating, optional: true
    builder.attribute :label,   Label,  optional: true
  end

  def declare_status_queries(builder)
    builder.query("OpenOnes")       { where(status: "open") }
    builder.query("NotClosed")      { where(status: { ne: "closed" }) }
    builder.query("InBothStatuses") { where(status: { in: "open,closed" }) }
    # A real Array whose members carry commas as content; splitting `value.to_s` on commas
    # would match nothing on Sqlite/Postgres while Memory reads the Array correctly.
    builder.query("NoteValuesIn") do
      where("note.value": { in: ["flagged: high, risk today", "high, risk, reviewed"] })
    end
    # An empty in-list is admitted (only lt/lte/gt/gte need a numeric field) and matches no rows
    # on every engine.
    builder.query("InNoStatuses") { where(status: { in: "" }) }
  end

  def declare_ordered_queries(builder)
    builder.query("BelowFloor") do
      attribute :floor, Money
      where(balance: { lt: :floor })
      order_by :balance
    end

    builder.query("AtLeast500Desc") do
      where(balance: { gte: { cents: 500 } })
      order_by :balance, :desc
    end

    # Selection only, with no order_by, like OpenOnes/NotClosed.
    builder.query("AtMost500") { where(balance: { lte: { cents: 500 } }) }
  end

  def declare_nested_path_queries(builder)
    builder.query("PriceAbove300") do
      where("box.price.cents": { gt: 300 })
      order_by :"box.price.cents"
      limit 2
    end

    builder.query("PriceAscOffset") do
      order_by :"box.price.cents"
      offset 1
    end

    builder.query("ByNameAsc") { order_by :name }
  end

  def declare_contains_queries(builder)
    builder.query("TaggedRed") { where(tags: { contains: "red" }) }

    builder.query("StatusContainsOpen") { where(status: { contains: "open" }) }

    # `note.value` carries a comma as content; `contains` is substring on every engine, so a
    # CSV-membership reading would diverge here.
    builder.query("NoteContainsPhrase") { where(note: { contains: "high, risk" }) }
  end

  def declare_null_queries(builder)
    declare_null_comparison_queries(builder)

    # A null on the compared-to value is a deliberate IS NULL / IS NOT NULL
    # (NullPolicy.sql_predicate); pinned against the case above so neither reading drifts.
    builder.query("LabelIsNull")    { where("label.value": nil) }
    builder.query("LabelIsNotNull") { where("label.value": { ne: nil }) }
    declare_null_ordering_queries(builder)
  end

  # A NULL satisfies no comparison; one case per comparator, each implemented separately.
  def declare_null_comparison_queries(builder)
    builder.query("LabelNotBeta")    { where("label.value": { ne: "beta" }) }
    builder.query("LabelIsAlpha")    { where("label.value": "alpha") }
    builder.query("RatingAbove200")  { where("rating.value": { gt: 200 }) }
    builder.query("RatingBelow400")  { where("rating.value": { lt: 400 }) }
    builder.query("RatingInList")    { where("rating.value": { in: "100,300" }) }
    builder.query("LabelContainsPh") { where("label.value": { contains: "ph" }) }
  end

  # Ordering is NullPolicy's other half: `order` in Ruby and `sql_order` in SQL agree only
  # by construction.
  def declare_null_ordering_queries(builder)
    builder.query("ByRatingNullsFirst") do
      order_by :"rating.value"
      nulls :first
    end
    builder.query("ByRatingNullsLast") do
      order_by :"rating.value"
      nulls :last
    end
  end

  let(:aggregate) { build_aggregate }

  # Every engine under test, by name, so a failure says which one. Postgres and D1 join only
  # when reachable.
  let(:engines) do
    found = { "Memory" => Hecks::Adapters::Memory.new(aggregate: aggregate), "Sqlite" => build_sqlite }
    found.merge!(build_postgres_engines) if postgres_available?
    found["D1"] = Hecks::Adapters::D1.new(aggregate: aggregate, settings: QueryAgreementD1Probe.settings) if d1_available?
    found
  end

  def build_sqlite
    Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "agreement.db" }, root: @dir)
  end

  def build_postgres_engines
    {
      "PostgresEra" => Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: AGREEMENT_DB }),
      "Postgres"    => Hecks::Adapters::Postgres.new(aggregate: aggregate, settings: { database: PLAIN_POSTGRES_AGREEMENT_DB })
    }
  end

  def instance(id, **fields)
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecks::Runtime::Value.for(aggregate, name, value) }
    built
  end

  # Five records distinct on every axis. `name` is not alphabetical in id order, so ByNameAsc
  # must really sort. `note` has a comma inside "high, risk" on r1/r4, and r2 has both words
  # split by a comma, pinning substring `contains`. `rating` and `label` are null on r2 and r4,
  # two nulls so ordering has a tie to break.
  RECORDS = {
    "r1" => { status: "open", balance: { cents: 100 }, box: { price: { cents: 100 } }, name: { value: "Eve" },
tags: [{ name: "red" }],   note: { value: "flagged: high, risk today" },      rating: { value: 100 }, label: { value: "alpha" } },
    "r2" => { status: "open", balance: { cents: 500 }, box: { price: { cents: 500 } }, name: { value: "Carol" },
tags: [{ name: "blue" }],  note: { value: "high risk, but flagged separately" } },
    "r3" => { status: "closed", balance: { cents: 900 }, box: { price: { cents: 900 } }, name: { value: "Alice" },
tags: [{ name: "green" }], note: { value: "nothing unusual" }, rating: { value: 300 }, label: { value: "beta" } },
    "r4" => { status: "closed", balance: { cents: 300 }, box: { price: { cents: 300 } }, name: { value: "Dave" },
tags: [{ name: "red" }],   note: { value: "high, risk, reviewed" } },
    "r5" => { status: "open", balance: { cents: 700 }, box: { price: { cents: 700 } }, name: { value: "Bob" },
tags: [{ name: "blue" }],  note: { value: "low risk" }, rating: { value: 500 }, label: { value: "phase" } }
  }.freeze

  def seed_records
    RECORDS.each do |id, fields|
      engines.each_value { |engine| engine.save(instance(id, **fields)) }
    end
  end

  # Scrubs each database first, then seeds every engine, in that order.
  before do
    scrub_postgres_databases
    scrub_d1_tables
    seed_records
  end

  # The ids each engine under test answers for the query, by engine name.
  def answers(query_name, args = {})
    engines.transform_values { |engine| engine.query(aggregate.query(query_name), args).map(&:id) }
  end

  # The hand-computed oracle, as every engine's expected answer.
  def everywhere(ids) = engines.transform_values { ids }

  it "compiles eq on the lifecycle field the same everywhere" do
    expect(answers("OpenOnes")).to eq(everywhere(%w[r1 r2 r5]))
  end

  it "compiles ne on the lifecycle field the same everywhere" do
    expect(answers("NotClosed")).to eq(everywhere(%w[r1 r2 r5]))
  end

  it "compiles in on the lifecycle field, matching every listed value, the same everywhere" do
    expect(answers("InBothStatuses")).to eq(everywhere(%w[r1 r2 r3 r4 r5]))
  end

  it "compiles an empty in-list as matching nothing, the same everywhere" do
    expect(answers("InNoStatuses")).to eq(everywhere([]))
  end

  it "compiles in on a real Array whose own members carry commas, the same everywhere" do
    expect(answers("NoteValuesIn")).to eq(everywhere(%w[r1 r4]))
  end

  it "compiles lt through a :symbol query argument on a bare value object, ordered, the same everywhere" do
    expect(answers("BelowFloor", { floor: { cents: 500 } })).to eq(everywhere(%w[r1 r4]))
  end

  it "compiles gte with a literal value on a bare value object, descending, the same everywhere" do
    expect(answers("AtLeast500Desc")).to eq(everywhere(%w[r3 r5 r2]))
  end

  it "compiles lte with a nested value object literal on a bare value object, the same everywhere" do
    expect(answers("AtMost500")).to eq(everywhere(%w[r1 r2 r4]))
  end

  it "compiles gt on a two-level nested path, ordered and limited, the same everywhere" do
    expect(answers("PriceAbove300")).to eq(everywhere(%w[r2 r5]))
  end

  it "orders by a two-level nested path ascending, with an offset, the same everywhere" do
    expect(answers("PriceAscOffset")).to eq(everywhere(%w[r4 r2 r5 r3]))
  end

  it "orders by a string value object ascending, the same everywhere" do
    expect(answers("ByNameAsc")).to eq(everywhere(%w[r3 r5 r2 r4 r1]))
  end

  it "compiles contains on a list of value objects, matching by member name, the same everywhere" do
    expect(answers("TaggedRed")).to eq(everywhere(%w[r1 r4]))
  end

  it "compiles contains on the lifecycle field for a comma-free, whole-value match, the same everywhere" do
    expect(answers("StatusContainsOpen")).to eq(everywhere(%w[r1 r2 r5]))
  end

  it "compiles contains as a real substring on a scalar field whose own content carries a comma, the same everywhere" do
    expect(answers("NoteContainsPhrase")).to eq(everywhere(%w[r1 r4]))
  end

  # r2 and r4 hold no rating or label and must be absent: a null is unknown and satisfies
  # no comparison.
  it "excludes nulls from ne, the same everywhere" do
    expect(answers("LabelNotBeta")).to eq(everywhere(%w[r1 r5]))
  end

  it "excludes nulls from eq, the same everywhere" do
    expect(answers("LabelIsAlpha")).to eq(everywhere(%w[r1]))
  end

  it "excludes nulls from gt, the same everywhere" do
    expect(answers("RatingAbove200")).to eq(everywhere(%w[r3 r5]))
  end

  it "excludes nulls from lt, the same everywhere" do
    expect(answers("RatingBelow400")).to eq(everywhere(%w[r1 r3]))
  end

  it "excludes nulls from in, the same everywhere" do
    expect(answers("RatingInList")).to eq(everywhere(%w[r1 r3]))
  end

  it "excludes nulls from contains, the same everywhere" do
    expect(answers("LabelContainsPh")).to eq(everywhere(%w[r1 r5]))
  end

  # Comparing to nil is a question about presence; pinned so neither null reading drifts.
  it "reads a comparison to nil as IS NULL, the same everywhere" do
    expect(answers("LabelIsNull")).to eq(everywhere(%w[r2 r4]))
  end

  it "reads ne nil as IS NOT NULL, the same everywhere" do
    expect(answers("LabelIsNotNull")).to eq(everywhere(%w[r1 r3 r5]))
  end

  it "places nulls first when asked, the same everywhere" do
    expect(answers("ByRatingNullsFirst")).to eq(everywhere(%w[r2 r4 r1 r3 r5]))
  end

  it "places nulls last when asked, the same everywhere" do
    expect(answers("ByRatingNullsLast")).to eq(everywhere(%w[r1 r3 r5 r2 r4]))
  end
end

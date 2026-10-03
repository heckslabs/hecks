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

    @available =
      begin
        if ENV.fetch("CLOUDFLARE_ACCOUNT_ID",
                     nil) && ENV.fetch("CLOUDFLARE_D1_DATABASE_ID", nil) && ENV["CLOUDFLARE_D1_API_TOKEN"]
          Hecks::Adapters::D1::Connection.new(
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

  before do
    next unless postgres_available?

    scrub = PG.connect(dbname: AGREEMENT_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close

    scrub_plain = PG.connect(dbname: PLAIN_POSTGRES_AGREEMENT_DB)
    scrub_plain.exec("DROP SCHEMA public CASCADE")
    scrub_plain.exec("CREATE SCHEMA public")
    scrub_plain.close
  end

  # D1 is one persistent database, so reset drops just the "Thing" tables, not the schema.
  before do
    next unless d1_available?

    scrub = Hecks::Adapters::D1::Connection.new(
      account_id:  ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
      database_id: ENV.fetch("CLOUDFLARE_D1_DATABASE_ID"),
      api_token:   ENV.fetch("CLOUDFLARE_D1_API_TOKEN")
    )
    scrub.execute("DROP TABLE IF EXISTS thing")
    scrub.execute("DROP TABLE IF EXISTS thing_entries")
    scrub.execute("DROP TABLE IF EXISTS events")
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

  # Declared whole so each query's fixture context stays beside the query it explains.
  # rubocop:disable-next Metrics/AbcSize
  # rubocop:disable-next Metrics/MethodLength
  def build_thing_aggregate
    Hecks::Bluebook::DSL::AggregateBuilder.new("Thing").tap do |builder|
      builder.lifecycle(:status, default: "open") do
        transition "Close" => "closed", from: "open"
      end

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
      # A real Array whose members carry commas as content; splitting `value.to_s` on commas
      # would match nothing on Sqlite/Postgres while Memory reads the Array correctly.
      builder.query("NoteValuesIn") do
        where("note.value": { in: ["flagged: high, risk today", "high, risk, reviewed"] })
      end
      # An empty in-list is admitted (only lt/lte/gt/gte need a numeric field) and matches no rows
      # on every engine.
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

      # Selection only, with no order_by, like OpenOnes/NotClosed.
      builder.query("AtMost500") { where(balance: { lte: { cents: 500 } }) }

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

      builder.query("TaggedRed") { where(tags: { contains: "red" }) }

      builder.query("StatusContainsOpen") { where(status: { contains: "open" }) }

      # `note.value` carries a comma as content; `contains` is substring on every engine, so a
      # CSV-membership reading would diverge here.
      builder.query("NoteContainsPhrase") { where(note: { contains: "high, risk" }) }

      # A NULL satisfies no comparison; one case per comparator, each implemented separately.
      builder.query("LabelNotBeta")    { where("label.value": { ne: "beta" }) }
      builder.query("LabelIsAlpha")    { where("label.value": "alpha") }
      builder.query("RatingAbove200")  { where("rating.value": { gt: 200 }) }
      builder.query("RatingBelow400")  { where("rating.value": { lt: 400 }) }
      builder.query("RatingInList")    { where("rating.value": { in: "100,300" }) }
      builder.query("LabelContainsPh") { where("label.value": { contains: "ph" }) }

      # A null on the compared-to value is a deliberate IS NULL / IS NOT NULL
      # (NullPolicy.sql_predicate); pinned against the case above so neither reading drifts.
      builder.query("LabelIsNull")    { where("label.value": nil) }
      builder.query("LabelIsNotNull") { where("label.value": { ne: nil }) }

      # Ordering is NullPolicy's other half: `order` in Ruby and `sql_order` in SQL agree only
      # by construction.
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

  let(:memory)   { Hecks::Adapters::Memory.new(aggregate: aggregate) }
  let(:sqlite)   { Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "agreement.db" }, root: @dir) }
  let(:postgres) { postgres_available? ? Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: AGREEMENT_DB }) : nil }
  let(:plain_postgres) do
    if postgres_available?
      Hecks::Adapters::Postgres.new(aggregate: aggregate,
                                    settings:  { database: PLAIN_POSTGRES_AGREEMENT_DB })
    end
  end
  let(:d1) do
    next nil unless d1_available?

    Hecks::Adapters::D1.new(
      aggregate: aggregate,
      settings:  {
        account_id:  ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
        database_id: ENV.fetch("CLOUDFLARE_D1_DATABASE_ID"),
        api_token:   ENV.fetch("CLOUDFLARE_D1_API_TOKEN")
      }
    )
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

  before do
    RECORDS.each do |id, fields|
      memory.save(instance(id, **fields))
      sqlite.save(instance(id, **fields))
      postgres&.save(instance(id, **fields))
      plain_postgres&.save(instance(id, **fields))
      d1&.save(instance(id, **fields))
    end
  end

  # Runs the query on every adapter under test and checks each against `expected`, the
  # hand-computed oracle. Postgres and D1 join only when reachable.
  def agree!(query_name, args = {}, expected:)
    declared = aggregate.query(query_name)

    expect(memory.query(declared, args).map(&:id)).to eq(expected)
    expect(sqlite.query(declared, args).map(&:id)).to eq(expected)
    expect(postgres.query(declared, args).map(&:id)).to eq(expected) if postgres_available?
    expect(plain_postgres.query(declared, args).map(&:id)).to eq(expected) if postgres_available?
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

  it "compiles lte with a nested value object literal on a bare value object, the same everywhere" do
    agree!("AtMost500", expected: %w[r1 r2 r4])
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

  # r2 and r4 hold no rating or label and must be absent: a null is unknown and satisfies
  # no comparison.
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

  # Comparing to nil is a question about presence; pinned so neither null reading drifts.
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

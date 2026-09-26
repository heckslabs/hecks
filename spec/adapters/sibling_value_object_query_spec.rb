require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"
require_relative "../support/postgres_probe"
require_relative "../support/sibling_value_object_domain"
# `pg` is required explicitly, as query_agreement_spec.rb does — the adapters
# only require it lazily, when they connect.
require "pg"

# **Why this gate exists**: `query_agreement_spec.rb` puts every engine side by
# side over an aggregate whose value objects are all its own. It cannot see a
# value object a sibling aggregate declares: the SQL builders looked the type up
# on the aggregate alone, found nothing, and read the column as plain text. A
# `where` over a jsonb column that holds `{"value":"s1"}` then compared that
# whole object to the bare string `"s1"` and matched nothing, on every SQL
# engine, while Memory (which coerces through the chapter) answered correctly.
#
# The expectations are hand-computed, as in the agreement spec, so three
# engines sharing one bug cannot agree their way to green.
RSpec.describe "a query over a value object a sibling aggregate declares", :io do
  SIBLING_VO_DB       = "hecks_sibling_vo_spec".freeze
  SIBLING_VO_PLAIN_DB = "hecks_sibling_vo_spec_plain".freeze

  def postgres_available? = PostgresProbe.available?

  before(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    [SIBLING_VO_DB, SIBLING_VO_PLAIN_DB].each do |name|
      admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
      admin.exec("CREATE DATABASE #{name}")
    end
    admin.close
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    [SIBLING_VO_DB, SIBLING_VO_PLAIN_DB].each { |name| admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)") }
    admin.close
  end

  around do |example|
    @dir = Dir.mktmpdir("hecks-sibling-vo-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  let(:aggregate) { SiblingValueObjectDomain.chapter.aggregate("Booking") }
  let(:memory)    { Hecks::Adapters::Memory.new(aggregate: aggregate) }
  let(:sqlite) do
    Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "sibling.db" }, root: @dir)
  end
  let(:postgres_era) do
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: { database: SIBLING_VO_DB })
  end
  let(:postgres) do
    Hecks::Adapters::Postgres.new(aggregate: aggregate, settings: { database: SIBLING_VO_PLAIN_DB })
  end

  # Every engine that can run here, by name, so a failure says which one.
  let(:engines) do
    engines = { "Memory" => memory, "Sqlite" => sqlite }
    engines.merge!("PostgresEra" => postgres_era, "Postgres" => postgres) if postgres_available?
    engines
  end

  before do
    if postgres_available?
      [SIBLING_VO_DB, SIBLING_VO_PLAIN_DB].each do |name|
        scrub = PG.connect(dbname: name)
        scrub.exec("DROP SCHEMA public CASCADE")
        scrub.exec("CREATE SCHEMA public")
        scrub.close
      end
    end

    { "b1" => ["s1", 9, %w[red]], "b2" => ["s2", 10, %w[blue]], "b3" => ["s3", 100, %w[red blue]] }
      .each do |id, (reference, level, tags)|
      engines.each_value { |engine| engine.save(booking(id, reference, level, tags)) }
    end
  end

  def booking(id, reference, level, tags)
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
    built[:label] = Hecks::Runtime::Value.for(aggregate, :label, id)
    built[:site_reference] = Hecks::Runtime::Value.for(aggregate, :site_reference, { value: reference })
    built[:tier] = Hecks::Runtime::Value.for(aggregate, :tier, { level: level })
    built[:tags] = Hecks::Runtime::Value.for(aggregate, :tags, tags.map { |name| { name: name } })
    built
  end

  def ids_from(engine, query_name, args = {})
    engine.query(aggregate.query(query_name), args).map(&:id)
  end

  it "matches a bare scalar argument the same everywhere" do
    engines.each do |name, engine|
      expect(ids_from(engine, "BySite", { site_reference: "s2" })).to eq(%w[b2]), "#{name} disagreed"
    end
  end

  it "matches a value-object argument the same everywhere" do
    engines.each do |name, engine|
      expect(ids_from(engine, "BySite", { site_reference: { value: "s3" } })).to eq(%w[b3]), "#{name} disagreed"
    end
  end

  it "matches nothing for an argument no row holds, the same everywhere" do
    engines.each do |name, engine|
      expect(ids_from(engine, "BySite", { site_reference: "nope" })).to eq([]), "#{name} disagreed"
    end
  end

  it "orders by the sibling's value object the same everywhere" do
    engines.each do |name, engine|
      expect(ids_from(engine, "BySiteDesc")).to eq(%w[b3 b2 b1]), "#{name} disagreed"
    end
  end

  # 9, 10 and 100: read as text they sort "10", "100", "9", so a builder that misses the
  # numeric member of a sibling's value object orders the wrong rows.
  it "orders by a sibling value object's numeric member, numerically, the same everywhere" do
    engines.each do |name, engine|
      expect(ids_from(engine, "TierDesc")).to eq(%w[b3 b2 b1]), "#{name} disagreed"
    end
  end

  it "matches list membership over a sibling value object the same everywhere" do
    engines.each do |name, engine|
      expect(ids_from(engine, "TaggedRed")).to eq(%w[b1 b3]), "#{name} disagreed"
    end
  end

  it "reads the stored value back as the sibling's value object everywhere" do
    engines.each do |name, engine|
      stored = engine.find("b1").site_reference

      expect(stored.to_h).to eq({ value: "s1" }), "#{name} disagreed"
    end
  end
end

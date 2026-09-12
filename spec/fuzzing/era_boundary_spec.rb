require "hecks/fuzzing/era_boundary"
require "hecks/ports/persistence/plugins/era"
require_relative "../support/postgres_probe"
require "tmpdir"
require "fileutils"
require "tempfile"
require "pg"
require "json"

# `Hecks::Fuzzing::EraBoundary`, PROVEN AGAINST A REAL DIVERGED WRITE —
# not a stand-in for it. This module exists to answer, automatically,
# the exact question `bin/merge_tail`'s own diagnostic line already
# answers by hand (`spec/adapters/driven/postgres_era/lineage_spec.rb`'s
# own "however a post-cut row lands in a superseded era..." example is
# where that arithmetic is proven at the lowest level); this file proves
# the THIN WRAPPER around it — real file-based domain loading, real
# `BindingPolicy` resolution, real connection settings read off a real
# `.world` — reaches the same answer.
RSpec.describe Hecks::Fuzzing::EraBoundary, :io do
  ERA_BOUNDARY_SPEC_DATABASE = "hecks_era_boundary_spec".freeze

  # THE SAME TWO-SHAPE RECIPE `lineage_spec.rb` ALREADY PROVES CORRECT,
  # deliberately NAMED so it never collides with that file's own
  # `V1_SOURCE`/`V2_SOURCE` — both are written directly inside an
  # `RSpec.describe do ... end` block, which assigns at TOP-LEVEL
  # (`Object`) scope, not inside the example-group class (that file's
  # own `PERSISTENCE_PARITY_FIXTURE_BLUEBOOK` comment explains the real
  # gotcha this avoids: two files naming the same constant this way
  # silently clobber each other, whichever loads last).
  ERA_BOUNDARY_V1_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "EraBoundaryFixture" do
      aggregate "Widget" do
        identified_by :kind

        attribute :cost, Money
        attribute :kind, Kind

        value_object "Money" do
          attribute :cents, Integer
        end

        value_object "Kind" do
          attribute :label, String
        end
      end
    end
  BLUEBOOK

  ERA_BOUNDARY_V2_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "EraBoundaryFixture" do
      aggregate "Widget" do
        identified_by :kind

        attribute :amount, Money
        attribute :kind, Kind

        value_object "Money" do
          attribute :cents, Integer
        end

        value_object "Kind" do
          attribute :label, String
        end
      end
    end
  BLUEBOOK

  ERA_BOUNDARY_EDGE_SOURCE = <<~RUBY.freeze
    Hecks.data_translation("EraBoundaryFixture", from: FROM_LABEL, to: TO_LABEL) do
      aggregate("Widget") do
        rename :cost, to: :amount
      end
    end
  RUBY

  def database_url = "postgres://localhost/#{ERA_BOUNDARY_SPEC_DATABASE}"

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{ERA_BOUNDARY_SPEC_DATABASE} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{ERA_BOUNDARY_SPEC_DATABASE}")
    admin.close
  end

  after(:all) do
    next unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{ERA_BOUNDARY_SPEC_DATABASE} WITH (FORCE)")
    admin.close
  end

  # THE SAME `check!` SHAPE `lineage_spec.rb` ALREADY PROVES — an
  # in-memory registry (a real `Kernel.eval`'d bluebook, never a file on
  # disk: this is SETUP, building real database state to later read back,
  # not the thing under test) minted/verified against the real database.
  def check!(source, translation_source: nil)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    file = Tempfile.new(["era-boundary-", ".bluebook"])
    file.write(source)
    file.flush
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      Kernel.eval(translation_source, TOPLEVEL_BINDING) if translation_source
    end
    bluebook = registry.bluebooks.values.first
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source,
      settings: { database: database_url, allow_superuser: true }
    )
    registry
  ensure
    file&.close!
  end

  def hash_of(source)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING)
    end
    Hecks::Runtime::StorageShape.mint_hash(registry.bluebooks.values.first)
  end

  def label_of(source) = hash_of(source)[0, 6]

  def write_v1_record(id)
    registry = check!(ERA_BOUNDARY_V1_SOURCE)
    aggregate = registry.bluebooks.values.first.aggregate("Widget")
    adapter = Hecks::Adapters::PostgresEra.new(aggregate: aggregate,
                                               settings:  { database: database_url, domain: "EraBoundaryFixture" })
    instance = Hecks::Runtime::Instance.new(
      aggregate: aggregate, id: id, state: { cost: { "cents" => 100 }, kind: { "label" => "biz" } }
    )
    adapter.save(instance)
  end

  # A REAL FILE-BASED DOMAIN, THE FIXTURE THE MODULE UNDER TEST ACTUALLY
  # LOADS — `Hecks::Fuzzing::EraBoundary.diverged_ancestor_writes` boots
  # from a real directory (`Hecks::Ports::Loading.bootstrap`, the exact
  # mechanism `bin/merge_tail` itself uses), never an in-memory registry
  # the way `check!` above sets state up with. The shape written here
  # does not need to match whichever era is current in the database at
  # all — this module never verifies a shape hash, only ever reads
  # `hecks_eras`/the journal directly (see its own header) — so ANY
  # PostgresEra-bound aggregate pointed at the right database answers
  # correctly regardless of which V it declares.
  def write_fixture_files!(root, bluebook_source)
    File.write(File.join(root, "fixture.bluebook"), bluebook_source)
    File.write(File.join(root, "fixture.hecksagon"), <<~RUBY)
      Hecks.hecksagon "EraBoundaryFixture" do
        EraBoundaryFixture::Widget.persisted_by("PostgresEra")
      end
    RUBY
    File.write(File.join(root, "fixture.world"), <<~RUBY)
      Hecks.world "EraBoundaryFixture" do
        persisted_by("PostgresEra") do
          database "#{database_url}"
          allow_superuser true
        end
      end
    RUBY
  end

  around do |example|
    Dir.mktmpdir("era_boundary_spec") do |dir|
      @fixture_root = dir
      example.run
    end
  end

  before do
    scrub = PG.connect(dbname: ERA_BOUNDARY_SPEC_DATABASE)
    scrub.exec("SET client_min_messages = warning")
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
  end

  it "reports checked: false for a domain not bound to PostgresEra at all" do
    write_fixture_files!(@fixture_root, ERA_BOUNDARY_V1_SOURCE)
    File.delete(File.join(@fixture_root, "fixture.hecksagon"))
    File.write(File.join(@fixture_root, "fixture.hecksagon"), <<~RUBY)
      Hecks.hecksagon "EraBoundaryFixture" do
        EraBoundaryFixture::Widget.persisted_by("Memory")
      end
    RUBY
    File.delete(File.join(@fixture_root, "fixture.world"))

    result = described_class.diverged_ancestor_writes(@fixture_root)

    expect(result[:checked]).to be(false)
    expect(result[:reason]).to include("not PostgresEra")
  end

  it "reports checked: true, diverged_total: 0 for a domain on its very first era" do
    check!(ERA_BOUNDARY_V1_SOURCE)
    write_fixture_files!(@fixture_root, ERA_BOUNDARY_V1_SOURCE)

    result = described_class.diverged_ancestor_writes(@fixture_root)

    expect(result).to eq(checked: true, era_count: 1, breakdown: [], diverged_total: 0)
  end

  # THE FINDING THIS MODULE EXISTS TO SURFACE — the exact recipe
  # `lineage_spec.rb`'s own "however a post-cut row lands in a
  # superseded era..." example already proves at the SQL level, read
  # back through this module's own public API instead.
  it "reports the finding: a real post-cut write an ancestor era still holds, nothing has merged forward" do
    write_v1_record("w1")
    from = label_of(ERA_BOUNDARY_V1_SOURCE)
    to = label_of(ERA_BOUNDARY_V2_SOURCE)
    edge = ERA_BOUNDARY_EDGE_SOURCE.sub("FROM_LABEL", from.inspect).sub("TO_LABEL", to.inspect)
    check!(ERA_BOUNDARY_V2_SOURCE, translation_source: edge)

    db = PG.connect(dbname: ERA_BOUNDARY_SPEC_DATABASE)
    state = JSON.generate(cost: { "cents" => 5 }, kind: { "label" => "biz" })
    ordinal = db.exec_params(
      "INSERT INTO hecks_journal_era_boundary_fixture (era, aggregate, aggregate_id, operation, state) " \
      "VALUES (1, 'widget', $1, 'save', $2) RETURNING ordinal",
      ["w9", state]
    )[0]["ordinal"]
    db.exec_params("INSERT INTO widget_head_snapshot_1 (id, ordinal, state) VALUES ($1, $2, $3)",
                   ["w9", ordinal, state])
    db.close

    write_fixture_files!(@fixture_root, ERA_BOUNDARY_V2_SOURCE)
    result = described_class.diverged_ancestor_writes(@fixture_root)

    expect(result[:checked]).to be(true)
    expect(result[:era_count]).to eq(2)
    expect(result[:diverged_total]).to eq(1)
    expect(result[:breakdown]).to eq([{ ordinal: 1, diverged: 1 }])
  end
end

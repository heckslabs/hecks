require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"

# examples/directory is the corpus's own real `rekey` (and `compute`)
# example — the exact `identified_by :name` -> `identified_by :email`
# story docs/implemented/guides/schema-evolution.md's rekey section
# already describes, landed for real instead of only in a spec fixture
# (lineage_spec.rb's own Roster/Person test proves the mechanism works,
# but invents both eras and the edge inline — none of it lives in
# examples/, so word_coverage_spec.rb's own corpus scan has never once
# seen a real `rekey` declaration). This spec loads era 2's bluebook
# AND the translation edge straight off disk — the same files a real
# checkout ships — and mints them against a real Postgres, seeded with
# several distinct historical records, not one hand-picked name: a
# `backfill` default could only ever be right for at most one of them,
# which is exactly why the committed edge uses `compute` instead (see
# the edge file's own comment). Runs only when a Postgres server is
# reachable — the shared probe in support/postgres_probe.rb, like every
# other Postgres spec here.
RSpec.describe "the Directory example's real rekey edge (examples/directory)", :io do
  DIRECTORY_DB = "hecks_directory_rekey_spec".freeze
  DOMAIN_ROOT = File.expand_path("../../../../examples/directory", __dir__).freeze

  # Era 1, held the first time this domain ever booted against a real
  # Postgres — never committed (data/eras/ is gitignored, same as
  # pizzas' own era 1). Kept here, inline, as the historical record it
  # actually is; directory.bluebook and its translation edge below are
  # read from the real committed files, not reinvented for this spec.
  ERA_1_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Directory" do
      aggregate "Member" do
        attribute :name,  MemberName
        attribute :title, MemberTitle

        identified_by :name

        value_object("MemberName")  { attribute :value, String }
        value_object("MemberTitle") { attribute :value, String }
      end
    end
  BLUEBOOK

  ERA_2_SOURCE = File.read(File.join(DOMAIN_ROOT, "bluebook/directory.bluebook")).freeze
  edge_files = Dir[File.join(DOMAIN_ROOT, "bluebook/translations/*.bluebook")]
  raise "expected exactly one translation edge in examples/directory, found #{edge_files.size}" unless edge_files.size == 1

  EDGE_SOURCE = File.read(edge_files.first).freeze

  before(:all) do
    skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DIRECTORY_DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{DIRECTORY_DB}")
    admin.close
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DIRECTORY_DB} WITH (FORCE)")
    admin.close
  end

  def load_registry(source, translation_source: nil)
    registry = Hecks::Runtime::Registry.new
    loading = Hecks::Ports::Loading.bootstrap
    file = Tempfile.new(["directory-rekey-", ".bluebook"])
    file.write(source)
    file.flush
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, file.path, 1)
      eval(translation_source) if translation_source
    end
    registry
  ensure
    file&.close!
  end

  def check!(source, translation_source: nil)
    registry = load_registry(source, translation_source: translation_source)
    bluebook = registry.bluebooks.values.first
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: { database: DIRECTORY_DB }
    )
    registry
  end

  def adapter_for(registry)
    member = registry.bluebooks.values.first.aggregate("Member")
    Hecks::Adapters::PostgresEra.new(aggregate: member, settings: { database: DIRECTORY_DB, domain: "Directory" })
  end

  # One end-to-end scenario: seed several distinct historical records,
  # prove the mint refuses the rekey without a human approval, approve
  # it, mint, then check every record resolved under its new identity
  # AND the raw journal stayed untouched. Splitting would either re-pay
  # the real-Postgres seed/mint setup or separate the approval gate
  # from the multi-row proof it exists to establish.
  # rubocop:disable-next RSpec/ExampleLength
  it "mints the committed edge — a real compute+rekey pair, agreeing on more than one row" do
    registry = check!(ERA_1_SOURCE)
    adapter = adapter_for(registry)
    member = registry.bluebooks.values.first.aggregate("Member")

    [
      ["Ada Lovelace", "Engineer"],
      ["Grace Hopper", "Rear Admiral"],
      ["Grace Chen",   "Analyst"]
    ].each do |name, title|
      adapter.save(Hecks::Runtime::Instance.new(
                     aggregate: member, id: name,
                     state: { name: { "value" => name }, title: { "value" => title } }
                   ))
    end

    # a rekey (like compute) is exempt from every per-record mechanical
    # check but one — Layer 3's human-approved sample is the only other
    # verification, so the mint refuses non-interactively without it
    expect { check!(ERA_2_SOURCE, translation_source: EDGE_SOURCE) }.to raise_error(
      Hecks::Runtime::WiringError, /this edge carries a compute or rekey rule/
    )

    drifted = load_registry(ERA_2_SOURCE, translation_source: EDGE_SOURCE)
    db = PG.connect(dbname: DIRECTORY_DB)
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Directory")
    lineage.record_approval!(
      from: drifted.translations.first.from, to: drifted.translations.first.to,
      edge_digest: Hecks::Translation::Audit.edge_digest(drifted.translations.first)
    )
    db.close

    check!(ERA_2_SOURCE, translation_source: EDGE_SOURCE)

    head = adapter_for(drifted)
    {
      "ada.lovelace@example.com" => ["Ada Lovelace", "Engineer"],
      "grace.hopper@example.com" => ["Grace Hopper", "Rear Admiral"],
      "grace.chen@example.com"   => ["Grace Chen", "Analyst"]
    }.each do |email, (original_name, title)|
      found = head.find(email)
      expect(found).not_to be_nil, "expected #{original_name} to resolve under #{email}"
      expect(found.email.to_h).to eq(value: email)
      expect(found.title.to_h).to eq(value: title)
      expect(head.find(original_name)).to be_nil
    end

    # the raw journal never rewrites — every row is still keyed by the
    # name it was actually saved under
    db = PG.connect(dbname: DIRECTORY_DB)
    raw = db.exec("SELECT aggregate_id FROM hecks_journal_directory ORDER BY aggregate_id").map { |r| r["aggregate_id"] }
    db.close
    expect(raw).to eq(["Ada Lovelace", "Grace Chen", "Grace Hopper"])
  end
end

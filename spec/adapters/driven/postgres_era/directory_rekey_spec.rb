require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"

# Mints examples/directory's committed rekey edge against a real Postgres, seeded with
# several distinct records (a `backfill` default could fit at most one, hence `compute`).
RSpec.describe "the Directory example's real rekey edge (examples/directory)", :io do
  include EraRegistryLoading

  DIRECTORY_DB = "hecks_directory_rekey_spec".freeze
  DOMAIN_ROOT = File.expand_path("../../../../examples/directory", __dir__).freeze

  # Era 1 is never committed (data/eras/ is gitignored), so it lives inline here.
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
    # PostgresEra refuses to boot as a superuser; see support/fenced_owner.rb
    FencedOwner.own!(DIRECTORY_DB)
  end

  after(:all) do
    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DIRECTORY_DB} WITH (FORCE)")
    admin.close
  end

  def scrub_database!
    scrub = PG.connect(dbname: DIRECTORY_DB)
    scrub.exec("DROP SCHEMA public CASCADE")
    scrub.exec("CREATE SCHEMA public")
    scrub.close
    FencedOwner.own_public!(DIRECTORY_DB)
  end

  def check!(source, translation_source: nil)
    registry = load_registry(source, translation_source: translation_source)
    bluebook = registry.bluebooks.values.first
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: bluebook, current_text: source, settings: { database: FencedOwner.url(DIRECTORY_DB) }
    )
    registry
  end

  def adapter_for(registry)
    member = registry.bluebooks.values.first.aggregate("Member")
    Hecks::Adapters::PostgresEra.new(aggregate: member, settings: { database: DIRECTORY_DB, domain: "Directory" })
  end

  MEMBERS_BY_EMAIL = {
    "ada.lovelace@example.com" => ["Ada Lovelace", "Engineer"],
    "grace.hopper@example.com" => ["Grace Hopper", "Rear Admiral"],
    "grace.chen@example.com"   => ["Grace Chen", "Analyst"]
  }.freeze

  # Era 1 with several distinct records saved, so the rekey is proven on more than one row.
  def seed_era_one!
    registry = check!(ERA_1_SOURCE)
    adapter = adapter_for(registry)
    member = registry.bluebooks.values.first.aggregate("Member")
    MEMBERS_BY_EMAIL.each_value do |name, title|
      state = { name: { "value" => name }, title: { "value" => title } }
      adapter.save(Hecks::Runtime::Instance.new(aggregate: member, id: name, state: state))
    end
  end

  def drifted_registry = load_registry(ERA_2_SOURCE, translation_source: EDGE_SOURCE)

  def approve_edge!(drifted)
    edge = drifted.translations.first
    db = PG.connect(dbname: DIRECTORY_DB)
    Hecks::Adapters::PostgresEra::Lineage.new(db, "Directory").record_approval!(
      from: edge.from, to: edge.to, edge_digest: Hecks::Translation::Audit.edge_digest(edge)
    )
    db.close
  end

  def journal_ids
    db = PG.connect(dbname: DIRECTORY_DB)
    db.exec("SELECT aggregate_id FROM hecks_journal_directory ORDER BY aggregate_id").map { |r| r["aggregate_id"] }
  ensure
    db&.close
  end

  before do
    scrub_database!
    seed_era_one!
  end

  # a rekey is exempt from per-record checks, so the mint refuses without human approval
  it "refuses to mint a compute+rekey edge nobody approved" do
    expect { check!(ERA_2_SOURCE, translation_source: EDGE_SOURCE) }.to raise_error(
      Hecks::Runtime::WiringError, /this edge carries a compute or rekey rule/
    )
  end

  context "when the edge is approved and minted" do
    let(:drifted) { drifted_registry }
    let(:head) { adapter_for(drifted) }

    before do
      approve_edge!(drifted)
      check!(ERA_2_SOURCE, translation_source: EDGE_SOURCE)
    end

    it "resolves every record under its rekeyed email, and no longer under its old name", :aggregate_failures do
      MEMBERS_BY_EMAIL.each do |email, (name, title)|
        found = head.find(email)
        expect(found).not_to be_nil, "expected #{name} to resolve under #{email}"
        expect([found.email.to_h, found.title.to_h, head.find(name)]).to eq([{ value: email }, { value: title }, nil])
      end
    end

    it "never rewrites the raw journal" do
      expect(journal_ids).to eq(["Ada Lovelace", "Grace Chen", "Grace Hopper"])
    end
  end
end

require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tmpdir"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/mint_request_support"
require_relative "../../../support/first_era_hold"
require_relative "../../../../lib/hecks/hecks/adapters/journal_store"

# The boot and the boot status resolve through one resolution (`LineageManager::EraResolution`):
# against the same database they name the same status and the same era for current, unminted,
# behind and superseded shapes; the status reads the database and writes nothing to it; and a
# domain that declares a database is answered from it, not from its committed `shapes.json`.
RSpec.describe "the boot status and the boot resolving through one resolution", :io do
  include EraRegistryLoading
  include MintRequestSupport
  include FirstEraHold

  RESOLUTION_DB = "hecks_boot_status_resolution_spec".freeze

  scratch_postgres RESOLUTION_DB, fenced: true

  def url = FencedOwner.url(RESOLUTION_DB)

  def shape_v1 = shape("cost")

  def shape_v2 = shape("amount")

  # Held by no era, and no edge leads to it.
  def shape_v3 = shape("total")

  def shape(field)
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :kind

          attribute :#{field}, Money
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
  end

  def label_of(source) = Hecks::Runtime::StorageShape.mint_label(load_registry(source).bluebooks.values.first)

  def edge_v1_to_v2
    <<~RUBY
      Hecks.data_translation("Ledger", from: #{label_of(shape_v1).inspect}, to: #{label_of(shape_v2).inspect}) do
        aggregate("Acct") do
          rename :cost, to: :amount
        end
      end
    RUBY
  end

  # Boots the era check of `source`, as a copy that owns the database would.
  def boot(source, translation_source: nil, settings: {})
    registry = load_registry(source, translation_source: translation_source)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: { database: url, mint_eras: true }.merge(settings)
    )
    registry
  end

  # What the boot status answers for `source` against the same database.
  def status(source, translation_source: nil)
    registry = load_registry(source, translation_source: translation_source)
    Hecks::Adapters::PostgresEra.era_status(registry: registry, bluebook: registry.bluebooks.values.first,
                                            settings: { database: url })
  end

  # The status the boot recorded on its registry, in the words the boot status uses.
  def booted_status(registry)
    return "superseded" if registry.superseded_eras["Ledger"]
    return "behind" if registry.behind_eras["Ledger"]
    return "unminted" if registry.unminted_eras["Ledger"]

    "current"
  end

  # The boot's and the status's answer for `source`: the status and the era each resolves to.
  def both(source, translation_source: nil)
    registry = boot(source, translation_source: translation_source)
    answer = status(source, translation_source: translation_source)
    { boot: [booted_status(registry), registry.resolved_eras["Ledger"]], status: [answer.status, answer.ordinal] }
  end

  # Names era 1, as a mint leaving it would, so an edge from its label can lead on.
  def name_first_era!
    db = Hecks::Adapters::PostgresEra.connect_for("Ledger", { database: url })
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    Hecks::Adapters::PostgresEra::LineageManager.ensure_named!(lineage, lineage.eras.first)
  ensure
    db&.close
  end

  def mint_request_settings
    { mint_request: { confirm: true, verdict: "would_mint", watermark: watermark_of(url, "Ledger") } }
  end

  # Every relation in the database and every table's row count, as one comparable value.
  def database_state
    db = PG.connect(url)
    tables = db.exec("SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " \
                     "WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') ORDER BY 1").map { |row| row["relname"] }
    tables.to_h { |table| [table, db.exec("SELECT count(*) AS n FROM #{db.quote_ident(table)}")[0]["n"]] }
  ensure
    db&.close
  end

  # A domain directory for `source`, its committed ledger holding `ledger_source`'s shape; with
  # `database`, a hecksagon and world that persist it in the scratch database.
  def domain_dir(root, source, ledger_source:, database:)
    dir = File.join(root, "bluebook")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "ledger.bluebook"), source)
    File.write(File.join(dir, "shapes.json"), JSON.generate("Ledger" => mint_hash_of(ledger_source)))
    write_wiring(dir) if database
    dir
  end

  def mint_hash_of(source) = Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)

  def write_wiring(dir)
    File.write(File.join(dir, "ledger.hecksagon"), %(Hecks.hecksagon "Ledger" do\n  persisted_by "PostgresEra"\nend\n))
    File.write(File.join(dir, "ledger.world"),
               %(Hecks.world "Ledger" do\n  persisted_by("PostgresEra") do\n    database "#{url}"\n  end\nend\n))
  end

  # The `Era.BootStatus` row for Ledger, for a domain whose ledger claims its shape is current.
  def boot_status_row(source, database:)
    Dir.mktmpdir do |root|
      dir = domain_dir(root, source, ledger_source: source, database: database)
      JSON.parse(Hecks::Adapters::JournalStore.new.boot_status(domain: dir)[:text])["bluebooks"]["Ledger"]
    end
  end

  # The row for Governance, a framework member the ledger holds though it commits no era adapter,
  # so with no database declared the ledger answers for it.
  def governance_row(source)
    Dir.mktmpdir do |root|
      dir = domain_dir(root, source.sub('"Ledger"', '"Governance"'), ledger_source: source, database: false)
      File.write(File.join(dir, "shapes.json"),
                 JSON.generate("Governance" => mint_hash_of(source.sub('"Ledger"', '"Governance"'))))
      JSON.parse(Hecks::Adapters::JournalStore.new.boot_status(domain: dir)[:text])["bluebooks"]["Governance"]
    end
  end

  before { hold_first_era!(url: url, domain: "Ledger", source: shape_v1) }

  it "agrees with the boot on a current shape" do
    expect(both(shape_v1)).to eq(boot: ["current", 1], status: ["current", 1])
  end

  it "agrees with the boot on an unminted shape" do
    expect(both(shape_v3)).to eq(boot: ["unminted", 1], status: ["unminted", 1])
  end

  it "agrees with the boot on a shape an edge leads the held era to" do
    name_first_era!
    expect(both(shape_v2, translation_source: edge_v1_to_v2)).to eq(boot: ["behind", 1], status: ["behind", 1])
  end

  context "with a checkout whose era a mint has superseded" do
    before { boot(shape_v2, translation_source: edge_v1_to_v2, settings: mint_request_settings) }

    it "agrees with the boot on the superseded shape" do
      expect(both(shape_v1)).to eq(boot: ["superseded", 1], status: ["superseded", 1])
    end
  end

  it "writes nothing to the database it reads", :aggregate_failures do
    before_state = database_state
    [shape_v1, shape_v3].each { |source| status(source) }
    expect(database_state).to eq(before_state)
  end

  it "answers from the declared database, not shapes.json", :aggregate_failures do
    row = boot_status_row(shape_v3, database: true)
    expect(row.values_at("status", "source", "ordinal")).to eq(["unminted", "database", 1])
  end

  it "answers from shapes.json, naming the ledger, when no database is declared" do
    expect(governance_row(shape_v3).values_at("status", "source")).to eq(%w[current ledger])
  end
end

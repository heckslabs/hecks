require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"

# What a boot with no mint request may do: read the held eras and report the shape it resolves to,
# and write nothing. The first era is held and minted by the mint entry point, never by a boot.
RSpec.describe "a boot with no mint request in PostgresRevision", :io do
  include EraRegistryLoading

  BOOT_READ_ONLY_DB = "hecks_boot_read_only_spec".freeze
  BOOT_READ_ONLY_FRESH_DB = "hecks_boot_read_only_fresh_spec".freeze
  DOMAIN = "Ledger".freeze

  scratch_postgres BOOT_READ_ONLY_DB, BOOT_READ_ONLY_FRESH_DB, fenced: true

  def held_url = FencedOwner.url(BOOT_READ_ONLY_DB)

  def fresh_url = FencedOwner.url(BOOT_READ_ONLY_FRESH_DB)

  def shape(field)
    <<~BLUEBOOK
      Hecks.bluebook "#{DOMAIN}" do
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

  def held_source = shape("cost")

  def unheld_source = shape("total")

  def registry_of(source) = load_registry(source)

  def bluebook_of(source) = registry_of(source).bluebooks.values.first

  def label_of(source) = Hecks::Runtime::StorageShape.mint_hash(bluebook_of(source))[0, 6]

  # Holds the first era the way the `hold_first` command does: lineage tables, the era, its heads.
  def hold_first!(source, url)
    bluebook = bluebook_of(source)
    db = Hecks::Adapters::PostgresRevision.connect_for(DOMAIN, { database: url })
    lineage = Hecks::Adapters::PostgresRevision::Lineage.new(db, DOMAIN)
    lineage.ensure_base!
    lineage.hold_first!(source, projection: Hecks::Runtime::StorageShape.project(bluebook))
    bluebook.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) }
  ensure
    db&.close
  end

  # The edge chain from the held era to the same shape, which needs no edge.
  def same_shape_chain
    registry = registry_of(held_source)
    label = label_of(held_source)
    Hecks::Adapters::PostgresRevision::LineageManager.edge_chain(
      registry, registry.bluebooks.values.first, [{ ordinal: 1, label: label }], label
    )
  end

  # Runs the boot's era check of `source` against `url`, with no mint request.
  def boot!(source, url: held_url)
    registry = registry_of(source)
    Hecks::Adapters::PostgresRevision::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: { database: url, mint_eras: true }
    )
    registry
  end

  # The rows of every lineage relation in the held database, each in a stable order.
  def lineage_rows
    db = Hecks::Adapters::PostgresRevision.connect_for(DOMAIN, { database: held_url })
    %w[hecks_eras hecks_era_texts].to_h { |table| [table, rows_of(db, table)] }
  ensure
    db&.close
  end

  def rows_of(db, table)
    db.exec("SELECT row_to_json(t)::text AS row FROM #{table} t ORDER BY 1").map { |row| row["row"] }
  end

  def relation_present?(url, name)
    db = Hecks::Adapters::PostgresRevision.connect_for(DOMAIN, { database: url })
    db.exec_params("SELECT to_regclass($1) IS NOT NULL AS present", [name])[0]["present"] == "t"
  ensure
    db&.close
  end

  before { hold_first!(held_source, held_url) }

  context "with a held shape" do
    it "writes no row to the journal or the era tables, byte for byte", :aggregate_failures do
      before_rows = lineage_rows
      boot!(held_source)
      expect(lineage_rows).to eq(before_rows)
    end

    it "reads the held era as current, with nothing minted" do
      registry = boot!(held_source)
      expect(registry.resolved_eras[DOMAIN]).to eq(1)
    end

    it "refuses a breaking move no edge covers, by name, and writes nothing", :aggregate_failures do
      before_rows = lineage_rows
      expect { boot!(unheld_source) }
        .to raise_error(Hecks::Runtime::WiringError, /cannot boot Ledger: no translation edge covers it/)
      expect(lineage_rows).to eq(before_rows)
    end
  end

  context "with a fresh database" do
    it "refuses toward the mint entry point, naming it" do
      expect { boot!(held_source, url: fresh_url) }
        .to raise_error(Hecks::Runtime::WiringError, /no era held; run the mint entry point/)
    end

    it "creates no lineage relation when it refuses", :aggregate_failures do
      expect { boot!(held_source, url: fresh_url) }.to raise_error(Hecks::Runtime::WiringError)
      expect(relation_present?(fresh_url, "hecks_eras")).to be(false)
    end
  end

  context "with a held era of the current shape and no edge file" do
    it "reads the era as current" do
      expect(boot!(held_source).resolved_eras[DOMAIN]).to eq(1)
    end

    it "needs no edge between the same shape" do
      expect(same_shape_chain).to eq([])
    end
  end
end

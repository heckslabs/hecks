require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/mint_request_support"

# A world that declares `disposable_ledger true`: a shape change needs no era, mint or edge. An
# additive one is applied in place, a breaking one moves the aggregate's rows to a dated archive
# and starts it empty, and a boot never refuses as unminted or superseded. A world without the
# declaration keeps its era guard.
RSpec.describe "a disposable ledger's boot in PostgresEra", :io do
  include EraRegistryLoading
  include MintRequestSupport

  LEDGER_DB = "hecks_disposable_ledger_boot_spec".freeze

  scratch_postgres LEDGER_DB, fenced: true

  def url = FencedOwner.url(LEDGER_DB)

  def shape_v1 = shape("attribute :name, Name")

  # Acct gains an optional attribute and the domain gains an aggregate: an additive change.
  def shape_added = shape("attribute :name, Name\n    attribute :note, Name, optional: true", MEMO)

  # Acct's attribute is renamed: the rows it stored do not fit the new shape.
  def shape_renamed = shape("attribute :title, Name")

  # An aggregate the additive change adds.
  MEMO = <<~BLUEBOOK.freeze
    aggregate "Memo" do
        identified_by :body
        attribute :body, Body
        value_object "Body" do
          attribute :value, String
        end
      end
  BLUEBOOK

  def shape(attributes, extra = "")
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :kind
          attribute :kind, Kind
          #{attributes}
          value_object("Kind") { attribute :label, String }
          value_object("Name") { attribute :value, String }
        end
        #{extra}
      end
    BLUEBOOK
  end

  def acct(field, value) = { kind: { "label" => "biz" }, field => { "value" => value } }

  # Boots the era check of `source`; `disposable: false` boots a world without the declaration.
  def boot(source, disposable: true, **settings)
    registry = load_registry(source, translation_source: settings.delete(:translation))
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: { database: url, disposable_ledger: disposable }.merge(settings)
    )
    registry
  end

  # The adapter a boot of `registry` builds for one aggregate, at the era the boot resolved.
  def adapter(registry, name = "Acct")
    Hecks::Adapters::PostgresEra.new(
      aggregate: registry.bluebooks.values.first.aggregate(name),
      settings:  { database: url, domain: "Ledger", era: registry.resolved_eras["Ledger"] }
    )
  end

  def write!(registry, state, name = "Acct", id: "acct-1")
    adapter(registry, name).append(Hecks::Ports::Persistence::Entry.new(operation: "save", id: id, state: state))
  end

  def sql(text)
    db = PG.connect(url)
    db.exec(text).to_a
  ensure
    db&.close
  end

  def held_eras = sql("SELECT ordinal FROM hecks_eras WHERE domain = 'Ledger'").size

  context "with a database that holds no era" do
    it "holds the first era itself and resolves to it", :aggregate_failures do
      expect(boot(shape_v1).resolved_eras["Ledger"]).to eq(1)
      expect(held_eras).to eq(1)
    end
  end

  context "with an additive change" do
    before do
      write!(boot(shape_v1), acct(:name, "kept"))
      @registry = boot(shape_added)
    end

    it "applies it in place, with no new era", :aggregate_failures do
      expect(@registry.resolved_eras["Ledger"]).to eq(1)
      expect(held_eras).to eq(1)
    end

    it "keeps the rows it held" do
      expect(adapter(@registry).find("acct-1").state[:name]["value"]).to eq("kept")
    end

    it "gives the added aggregate a head to write and read" do
      write!(@registry, { body: { "value" => "hello" } }, "Memo", id: "memo-1")
      expect(adapter(@registry, "Memo").count).to eq(1)
    end

    it "holds the booting shape, so a further boot finds nothing to change" do
      expect { boot(shape_added) }.not_to output.to_stderr
    end
  end

  context "with a breaking change" do
    before do
      write!(boot(shape_v1), acct(:name, "old"))
      @registry = boot(shape_renamed)
    end

    def archives = sql("SELECT aggregate, archive, row_count FROM hecks_ledger_archives")

    it "starts the aggregate empty, with no new era", :aggregate_failures do
      expect(adapter(@registry).count).to eq(0)
      expect(held_eras).to eq(1)
    end

    it "names the archive it made", :aggregate_failures do
      expect(archives.map { |row| row.values_at("aggregate", "row_count") }).to eq([%w[acct 1]])
      expect(archives.first["archive"]).to match(/\Aledger_acct_archived_\d{14}\z/)
    end

    it "keeps the old rows in the archive" do
      expect(sql(%(SELECT state->'name'->>'value' AS name FROM "#{archives.first["archive"]}")).first["name"]).to eq("old")
    end

    it "writes at the new shape" do
      write!(@registry, acct(:title, "new"))
      expect(adapter(@registry).find("acct-1").state[:title]["value"]).to eq("new")
    end
  end

  context "with a breaking change named on stderr" do
    before { write!(boot(shape_v1), acct(:name, "old")) }

    it "says what it archived" do
      expect { boot(shape_renamed) }.to output(/archived 1 journal row to ledger_acct_archived_\d{14}/).to_stderr
    end
  end

  context "with an older checkout booting after a newer one" do
    before do
      boot(shape_v1)
      boot(shape_added)
    end

    it "boots without refusing, as neither unminted nor superseded", :aggregate_failures do
      registry = boot(shape_v1)
      expect(registry.unminted_eras["Ledger"]).to be_nil
      expect(registry.superseded_eras["Ledger"]).to be_nil
    end
  end

  context "with a ledger an ordinary mint already moved to era 2" do
    def edge
      label = ->(source) { Hecks::Runtime::StorageShape.mint_label(load_registry(source).bluebooks.values.first) }
      %(Hecks.data_translation("Ledger", from: #{label.call(shape_v1).inspect}, to: #{label.call(shape_renamed).inspect}) do
          aggregate("Acct") { rename :name, to: :title }
        end)
    end

    before do
      write!(boot(shape_v1), acct(:name, "old"))
      settings = with_mint_request({ database: url, mint_eras: true }, domain: "Ledger")
      write!(boot(shape_renamed, disposable: false, translation: edge, **settings), acct(:title, "era two"))
      @registry = boot(shape_v1)
    end

    it "archives rows from every era and starts the aggregate empty at the latest", :aggregate_failures do
      expect(@registry.resolved_eras["Ledger"]).to eq(2)
      expect(adapter(@registry).count).to eq(0)
    end
  end

  context "with a world that does not declare the ledger disposable" do
    before { boot(shape_v1) }

    it "still boots an additive change unminted, as before" do
      expect(boot(shape_added, disposable: false).unminted_eras["Ledger"]).to eq(1)
    end

    it "still refuses to boot a database that holds no era" do
      ScratchPostgres.scrub([LEDGER_DB], fenced: true)
      expect { boot(shape_v1, disposable: false) }.to raise_error(Hecks::Runtime::WiringError, /no era held/)
    end
  end
end

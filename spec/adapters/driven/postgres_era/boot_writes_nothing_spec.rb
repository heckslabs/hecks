require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/first_era_hold"

# What a boot writes: nothing. A read-only boot of a provisioned database leaves its schema and
# every row as they were, a boot of a database no mint has provisioned refuses by name and creates
# nothing, and the first-era hold of the mint entry point provisions a fresh database so that a
# read-only boot of it works.
RSpec.describe "a boot's writes in PostgresEra", :io do
  include EraRegistryLoading
  include FirstEraHold

  BOOT_WRITES_DB = "hecks_boot_writes_nothing_spec".freeze
  BOOT_WRITES_FRESH_DB = "hecks_boot_writes_fresh_spec".freeze
  BOOT_WRITES_DOMAIN = "Ledger".freeze

  scratch_postgres BOOT_WRITES_DB, BOOT_WRITES_FRESH_DB, fenced: true

  def held_url = FencedOwner.url(BOOT_WRITES_DB)

  def fresh_url = FencedOwner.url(BOOT_WRITES_FRESH_DB)

  # One aggregate with a cached where-field and a declared query that reads it.
  def source
    <<~BLUEBOOK
      Hecks.bluebook "#{BOOT_WRITES_DOMAIN}" do
        aggregate "Acct" do
          identified_by :kind

          attribute :cost, Money
          attribute :kind, Kind

          query "Cheap" do
            where(:"cost.cents" => { lt: 500 })
          end

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

  def bluebook = load_registry(source).bluebooks.values.first

  def aggregate = bluebook.aggregate("Acct")

  def adapter_on(url, era: nil)
    settings = { database: url, domain: BOOT_WRITES_DOMAIN }
    settings[:era] = era if era
    Hecks::Adapters::PostgresEra.new(aggregate: aggregate, settings: settings)
  end

  # Boots the era check of the bluebook against `url` with no mint request, as a copy would.
  def boot_check!(url)
    registry = load_registry(source)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: { database: url, mint_eras: true }
    )
  end

  def save_acct(url)
    instance = Hecks::Runtime::Instance.new(
      aggregate: aggregate, id: "acct-1", state: { kind: { "label" => "biz" }, cost: { "cents" => 5 } }
    )
    adapter_on(url, era: 1).save(instance)
  end

  # Every relation, column, function, and every table's row count, as one comparable value.
  def database_state(url)
    db = PG.connect(url)
    {
      relations: relation_names(db),
      columns:   column_names(db),
      functions: function_names(db),
      rows:      row_counts(db)
    }
  ensure
    db&.close
  end

  def relation_names(db)
    db.exec("SELECT n.nspname || '.' || c.relname || ':' || c.relkind::text AS name FROM pg_class c " \
            "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' ORDER BY 1")
      .map { |row| row["name"] }
  end

  def column_names(db)
    db.exec("SELECT table_name, column_name, data_type FROM information_schema.columns " \
            "WHERE table_schema = 'public' ORDER BY 1, 2")
      .map { |row| row.values.join(" ") }
  end

  def function_names(db)
    db.exec("SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " \
            "WHERE n.nspname = 'public' ORDER BY 1").map { |row| row["proname"] }
  end

  def row_counts(db)
    tables = db.exec("SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " \
                     "WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') ORDER BY 1")
    tables.to_h { |row| [row["relname"], db.exec("SELECT count(*) AS n FROM #{db.quote_ident(row["relname"])}")[0]["n"]] }
  end

  before do
    hold_first_era!(url: held_url, domain: BOOT_WRITES_DOMAIN, source: source)
    save_acct(held_url)
  end

  it "leaves the schema and every row as they were across a read-only boot", :aggregate_failures do
    before_state = database_state(held_url)
    boot_check!(held_url)
    adapter_on(held_url).all
    expect(database_state(held_url)).to eq(before_state)
  end

  it "reads the saved record through the boot without writing it" do
    expect(adapter_on(held_url).find("acct-1")).not_to be_nil
  end

  it "refuses a boot of a database no mint has provisioned, naming the mint entry point", :aggregate_failures do
    expect { adapter_on(fresh_url) }.to raise_error(Hecks::Runtime::WiringError, /no era held/)
    expect(database_state(fresh_url)[:relations]).to eq([])
  end

  it "provisions a fresh database through the first-era hold, then boots it read-only", :aggregate_failures do
    hold_first_era!(url: fresh_url, domain: BOOT_WRITES_DOMAIN, source: source)
    expect(database_state(fresh_url)[:relations]).to include(a_string_including("public.events:r"),
                                                             a_string_including("public.hecks_fc_"))
    expect(adapter_on(fresh_url).count).to eq(0)
  end
end

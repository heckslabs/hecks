require "hecks"
require "tmpdir"
require "fileutils"
require "hecks/ports/persistence/plugins/era"
require_relative "../lib/hecks/quality_control/adapters/main_maintenance"
require_relative "support/postgres_probe"
require_relative "support/scratch_postgres"
require_relative "support/fenced_owner"
require_relative "support/era_registry_loading"
require_relative "support/mint_request_support"

# The Maintenance mint of a ledger, on a disposable database and a temporary ledger directory: the
# Mint ask runs the era check with the mint request, and each guard refuses by name. The real QA
# ledger is never touched.
RSpec.describe "the Maintenance mint of the QA ledger", :io do
  include EraRegistryLoading
  include MintRequestSupport

  MINT_SPEC_DB = "hecks_qa_era_mint_spec".freeze

  scratch_postgres MINT_SPEC_DB, fenced: true

  def refused = Hecks::Adapters::MainMaintenance::Refused

  def ledger_dir = File.join(@root, "qa", "bluebook")

  def sha = "a" * 40

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

  def label_of(source)
    Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
  end

  def write_ledger(source, translation: nil)
    File.write(File.join(ledger_dir, "ledger.bluebook"), source)
    return unless translation

    File.write(File.join(ledger_dir, "translations", "2-#{label_of(shape("amount"))}.bluebook"), translation)
  end

  # Writes the ledger's files: the bluebook, its world's database, and the hecksagon binding Acct to
  # PostgresEra.
  def write_files
    FileUtils.mkdir_p(File.join(ledger_dir, "translations"))
    write_world
    File.write(File.join(ledger_dir, "ledger.hecksagon"), <<~RUBY)
      Hecks.hecksagon "Ledger" do
        Ledger::Acct.persisted_by("PostgresEra")
      end
    RUBY
  end

  def write_world
    File.write(File.join(ledger_dir, "ledger.world"), <<~RUBY)
      Hecks.world "Ledger" do
        persisted_by("PostgresEra") do
          database "#{FencedOwner.url(MINT_SPEC_DB)}"
          mint_eras false
        end
      end
    RUBY
  end

  # Holds era 1 the way a first boot does: no mint, no request.
  def hold_first!
    held = Hecks::Adapters::JournalStore::HeldDomain.open(ledger_dir, mode: :translated)
    held.registry.adapter_class(held.adapter_name).era_check!(
      registry: held.registry, bluebook: held.bluebook, current_text: File.read(File.join(ledger_dir, "ledger.bluebook")),
      settings: held.settings, directory: held.directory
    )
  end

  def era_count
    connection = PG.connect(FencedOwner.url(MINT_SPEC_DB))
    connection.exec("SELECT count(*) AS n FROM hecks_eras WHERE domain = 'Ledger'")[0]["n"].to_i
  ensure
    connection&.close
  end

  def watermark = watermark_of(FencedOwner.url(MINT_SPEC_DB), "Ledger")

  def port = Hecks::Adapters::MainMaintenance.new(root: @root)

  def request(verdict: "would_mint", confirm: true)
    { confirm: confirm, verdict: verdict, watermark: watermark }
  end

  def mint_with(verdict: "would_mint", confirm: true, watermark: self.watermark, era: 2)
    port.mint(run: "r1", domain: "Ledger", era: era, sha: sha, branch: "qa/x", watermark: watermark,
              rehearsal_verdict: verdict, confirm: confirm)
  end

  before do
    @root = Dir.mktmpdir("qa-era-mint")
    stub_const("Hecks::Adapters::MainMaintenance::STRANDED_DIR", File.join(@root, "state"))
    write_files
    write_ledger(shape("cost"))
    hold_first!
    write_ledger(shape("amount"), translation: edge_v1_to_v2)
  end

  after { FileUtils.remove_entry(@root) }

  def edge_v1_to_v2
    <<~RUBY
      Hecks.data_translation("Ledger", from: #{label_of(shape("cost")).inspect},
                             to: #{label_of(shape("amount")).inspect}) do
        aggregate("Acct") do
          rename :cost, to: :amount
        end
      end
    RUBY
  end

  it "a moved watermark refuses by name, and the ledger keeps its era", :aggregate_failures do
    expect { mint_with(watermark: 99) }
      .to raise_error(refused, /ledger watermark moved from 99 to \d+ since the rehearsal/)
    expect(era_count).to eq(1)
  end

  it "the entry point mints only with a matching would_mint verdict and watermark", :aggregate_failures do
    expect(Hecks::Adapters::QaEraMint.call(@root, domain: "Ledger", era: 2, request: request(verdict: "would_refuse")))
      .to match([/rehearsal's verdict was would_refuse, not would_mint/, false])
    expect(era_count).to eq(1)
    expect(Hecks::Adapters::QaEraMint.call(@root, domain: "Ledger", era: 2, request: request))
      .to eq([label_of(shape("amount")), true])
  end

  it "refuses an unconfirmed mint by name, and mints the era once confirmed", :aggregate_failures do
    expect { mint_with(confirm: false) }.to raise_error(refused, /the mint was not confirmed/)
    expect(mint_with).to include(label: { value: label_of(shape("amount")) })
    expect(era_count).to eq(2)
  end
end

require "hecks"
require "tmpdir"
require "fileutils"
require_relative "../../../../lib/hecks/hecks/adapters/journal_store"

# The one mint per release. Each example builds a small era-adapter domain in a temporary
# directory, so the ledger is real and the mint is injected: no database is needed.
module ReleaseMintSupport
  ReleaseMint = Hecks::Adapters::JournalStore::ReleaseMint

  BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shop" do
      aggregate "Item" do
        identified_by :sku
        attribute :sku, Sku
        %<extra>s

        value_object "Sku" do
          attribute :code, String
        end

        value_object "Note" do
          attribute :text, String
        end
      end
    end
  RUBY

  def write_shop(directory, extra = "")
    File.write(File.join(directory, "shop.bluebook"), format(BLUEBOOK, extra: extra))
    File.write(File.join(directory, "shop.hecksagon"), %(Hecks.hecksagon "Shop" do\n  persisted_by "PostgresEra"\nend\n))
  end

  def release(directory, **)
    minted = []
    minter = ->(era, request) { [minted << [era, request], ["c3", true]].last.last }
    reader = ->(_dir) { { eraless: "Memory" } }
    [ReleaseMint.new(directory: directory, minter: minter, reader: reader).answer(run: "r-1", **), minted]
  end

  def ledger_hash(directory) = JSON.parse(File.read(File.join(directory, "shapes.json"))).fetch("Shop").fetch("hash")
end

RSpec.describe "release.mint, the one mint per release" do
  include ReleaseMintSupport

  let(:directory) { Dir.mktmpdir("release-mint") }

  before do
    write_shop(directory)
    Hecks::ShapeLedger.check(directory, confirm: true)
  end

  after { FileUtils.remove_entry(directory) }

  it "refuses without --confirm" do
    expect { release(directory) }.to raise_error(Hecks::Runtime::WiringError, /needs --confirm/)
  end

  it "moves the ledger over a change that only adds, commits nothing before it", :aggregate_failures do
    held = ledger_hash(directory)
    write_shop(directory, "attribute :note, Note, optional: true")
    expect(Hecks::ShapeLedger.check(directory)).to start_with("1 bluebook shapes")
    release(directory, confirm: true)

    expect(ledger_hash(directory)).not_to eq(held)
  end

  it "refuses by name a change that is neither additive nor covered, and leaves the ledger", :aggregate_failures do
    held = ledger_hash(directory)
    write_shop(directory, "attribute :note, Note")

    expect { release(directory, confirm: true) }
      .to raise_error(Hecks::Runtime::WiringError, /release mint refused: Shop: the shape moved/)
    expect(ledger_hash(directory)).to eq(held)
  end
end

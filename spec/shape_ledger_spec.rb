require "spec_helper"
require "tmpdir"
require "hecks/shape_ledger"

# The ledger holds each bluebook's storage shape and projection as of the last release mint. A shape
# that moves passes when it only adds or a translation edge covers it, commits nothing, and fails by
# name otherwise.
RSpec.describe Hecks::ShapeLedger do
  let(:directory) { Dir.mktmpdir("shape-ledger") }

  SHOP_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shop" do
      aggregate "Item" do
        identified_by :sku

        attribute :sku, Sku
        %<extra>s

        value_object "Sku" do
          attribute :code, String
        end

        value_object "Price" do
          attribute :cents, Integer
        end
      end
    end
  RUBY

  def write_bluebook(extra = "", persisted_by: "PostgresEra")
    File.write(File.join(directory, "shop.bluebook"), format(SHOP_BLUEBOOK, extra: extra))
    File.write(File.join(directory, "shop.hecksagon"), %(Hecks.hecksagon "Shop" do\n  persisted_by "#{persisted_by}"\nend\n))
  end

  def ledgered = JSON.parse(File.read(File.join(directory, "shapes.json"))).fetch("Shop").fetch("hash")

  def current = described_class.shapes_of(Hecks.describe(directory).registry).fetch("Shop")

  def write_edge(from, to)
    FileUtils.mkdir_p(File.join(directory, "translations"))
    File.write(File.join(directory, "translations", "2-#{to}.bluebook"),
               %(Hecks.data_translation "Shop", from: "#{from}", to: "#{to}" do\nend\n))
  end

  def moved_without_an_edge
    write_bluebook
    described_class.check(directory, confirm: true)
    write_bluebook("attribute :price, Price")
  end

  def moved_additively
    write_bluebook
    described_class.check(directory, confirm: true)
    write_bluebook("attribute :price, Price, optional: true")
  end

  def ledger_bytes = File.read(File.join(directory, "shapes.json"))

  after { FileUtils.remove_entry(directory) }

  it "has nothing to say about a ledger written from the shapes it describes" do
    write_bluebook
    described_class.check(directory, confirm: true)

    expect(described_class.check(directory)).to start_with("1 bluebook shapes, each the one the ledger holds")
  end

  it "holds each shape's hash and projection" do
    write_bluebook
    described_class.check(directory, confirm: true)

    expect(JSON.parse(ledger_bytes).fetch("Shop").keys).to eq(%w[hash projection])
  end

  it "passes a bluebook the ledger does not hold yet, since nothing it holds can be lost" do
    write_bluebook

    expect(described_class.check(directory)).to start_with("1 bluebook shapes")
  end

  it "refuses a shape that moved in a way that is not additive and no edge covers" do
    moved_without_an_edge

    expect { described_class.check(directory) }.to raise_error(described_class::Failure, /not provably additive/)
  end

  it "names how to write the rules when a shape moved with none" do
    moved_without_an_edge

    expect { described_class.check(directory) }.to raise_error(described_class::Failure, /scaffold_translation/)
  end

  it "refuses to rewrite the ledger over a shape no edge covers" do
    moved_without_an_edge

    expect { described_class.check(directory, confirm: true) }.to raise_error(described_class::Failure, /not provably additive/)
  end

  it "passes a move an edge covers, and rewrites the ledger only when confirmed", :aggregate_failures do
    moved_without_an_edge
    write_edge(described_class.label(ledgered), described_class.label(current))

    expect(described_class.check(directory)).to start_with("1 bluebook shapes")
    expect(described_class.check(directory, confirm: true)).to start_with("wrote 1 bluebook shapes")
  end

  it "passes a move that only adds and commits nothing: no ledger rewrite, no edge file", :aggregate_failures do
    moved_additively
    before = ledger_bytes

    expect(described_class.check(directory)).to start_with("1 bluebook shapes")
    expect(ledger_bytes).to eq(before)
  end

  it "reads a held entry whose projection does not hash to its hash as not additive" do
    moved_additively
    File.write(File.join(directory, "shapes.json"), JSON.generate("Shop" => { "hash" => "a" * 64, "projection" => {} }))

    expect { described_class.check(directory) }.to raise_error(described_class::Failure, /not provably additive/)
  end

  it "lists the refusals a release mint is held to" do
    moved_without_an_edge

    expect(described_class.refusals(directory).first).to include("Shop: the shape moved")
  end

  it "follows a chain of edges across more than one move" do
    moved_without_an_edge
    write_edge(described_class.label(ledgered), "aaaaaa")
    write_edge("aaaaaa", described_class.label(current))

    expect(described_class.check(directory, confirm: true)).to start_with("wrote 1 bluebook shapes")
  end

  describe "which bluebooks it holds" do
    it "skips a bluebook whose committed persistence is Memory, whatever shape it takes", :aggregate_failures do
      write_bluebook(persisted_by: "Memory")
      described_class.check(directory, confirm: true)
      write_bluebook("attribute :price, Price", persisted_by: "Memory")

      expect(described_class.check(directory)).to include("skipped 1 disposable bluebooks (committed persistence: Memory): Shop")
      expect(described_class.check(directory)).to start_with("0 bluebook shapes")
    end

    it "does not pull a bluebook in because a local overlay names an era adapter", :aggregate_failures do
      write_bluebook(persisted_by: "Memory")
      File.write(File.join(directory, "hecks.local.hecksagon"), %(Hecks.hecksagon "Shop" do\n  persisted_by "PostgresEra"\nend\n))

      expect(described_class::Scope.of(described_class::Scope.committed_registry(directory)).last).to eq("Shop" => "Memory")
    end

    it "leaves a skipped bluebook out of the status and the edge hygiene", :aggregate_failures do
      write_bluebook(persisted_by: "Memory")
      write_edge("aaaaaa", "aaaaaa")

      expect(described_class::Status.of(directory)["bluebooks"]).to be_empty
      expect(described_class.check(directory)).not_to include("self-loop")
    end

    it "holds a bluebook whose committed persistence is an era adapter", :aggregate_failures do
      write_bluebook
      expect(described_class::Scope.of(described_class::Scope.committed_registry(directory)).first).to eq(["Shop"])
    end
  end
end

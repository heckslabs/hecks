require "spec_helper"
require "tmpdir"
require "hecks/shape_ledger"

# The ledger holds each chapter's storage shape; a shape that moves needs a translation edge from
# the
# shape the ledger holds, and only then may the ledger move.
RSpec.describe Hecks::ShapeLedger do
  let(:directory) { Dir.mktmpdir("shape-ledger") }

  SHOP_CHAPTER = <<~RUBY.freeze
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

  def write_chapter(extra = "")
    File.write(File.join(directory, "shop.bluebook"), format(SHOP_CHAPTER, extra: extra))
  end

  def ledgered = JSON.parse(File.read(File.join(directory, "shapes.json"))).fetch("Shop")

  def current = described_class.shapes_of(Hecks.describe(directory).registry).fetch("Shop")

  def write_edge(from, to)
    FileUtils.mkdir_p(File.join(directory, "translations"))
    File.write(File.join(directory, "translations", "2-#{to}.bluebook"),
               %(Hecks.data_translation "Shop", from: "#{from}", to: "#{to}" do\nend\n))
  end

  def moved_without_an_edge
    write_chapter
    described_class.check(directory, confirm: true)
    write_chapter("attribute :price, Price")
  end

  after { FileUtils.remove_entry(directory) }

  it "has nothing to say about a ledger written from the shapes it describes" do
    write_chapter
    described_class.check(directory, confirm: true)

    expect(described_class.check(directory)).to eq("1 chapter shapes, each the one the ledger holds")
  end

  it "asks for a ledger when there is none" do
    write_chapter

    expect { described_class.check(directory) }.to raise_error(described_class::Failure, /Shop: not in the ledger/)
  end

  it "refuses a shape that moved with no translation edge from the ledgered one" do
    moved_without_an_edge

    expect { described_class.check(directory) }.to raise_error(described_class::Failure, /no translation edge from/)
  end

  it "prints the edge to commit when a shape moved with none", :aggregate_failures do
    moved_without_an_edge

    expect { described_class.check(directory) }
      .to raise_error(described_class::Failure, /Hecks\.data_translation "Shop", from: "\h{6}", to: "\h{6}" do end/)
  end

  it "refuses to rewrite the ledger over a shape no edge covers" do
    moved_without_an_edge

    expect { described_class.check(directory, confirm: true) }.to raise_error(described_class::Failure, /no translation edge/)
  end

  it "asks for the ledger to be rewritten once an edge covers the move", :aggregate_failures do
    moved_without_an_edge
    write_edge(described_class.label(ledgered), described_class.label(current))

    expect { described_class.check(directory) }.to raise_error(described_class::Failure, /an edge covers it/)
    expect(described_class.check(directory, confirm: true)).to start_with("wrote 1 chapter shapes")
  end

  it "settles a move that only adds in one step: writes the empty edge and moves the ledger", :aggregate_failures do
    moved_without_an_edge
    now = described_class.label(current)

    expect(described_class.check(directory, confirm: true, additive: true)).to include("1 empty edge(s)")
    expect(File.read(File.join(directory, "translations", "2-#{now}.bluebook"))).to include(%(to: "#{now}"))
  end

  it "has nothing left to say once an additive move is settled" do
    moved_without_an_edge
    described_class.check(directory, confirm: true, additive: true)

    expect(described_class.check(directory)).to eq("1 chapter shapes, each the one the ledger holds")
  end

  it "follows a chain of edges across more than one move" do
    moved_without_an_edge
    write_edge(described_class.label(ledgered), "aaaaaa")
    write_edge("aaaaaa", described_class.label(current))

    expect(described_class.check(directory, confirm: true)).to start_with("wrote 1 chapter shapes")
  end
end

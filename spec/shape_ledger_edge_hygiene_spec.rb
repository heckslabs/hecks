require "spec_helper"
require "hecks/shape_ledger"
require "tmpdir"
require "fileutils"

# Edge hygiene reads the edge files of a disposable directory against a ledger label and the current
# shape. It flags a self-loop, a fork and an orphan by file, and never a sole route.
RSpec.describe "edge hygiene in the shape ledger" do
  let(:hygiene) { Hecks::ShapeLedger::EdgeHygiene }
  let(:shapes) { { "Shop" => "dddddd1" } }
  let(:ledger) { { "Shop" => "dddddd9" } }
  let(:no_moves) { {} }

  def write_edges(dir, edges)
    FileUtils.mkdir_p(File.join(dir, "translations"))
    edges.each do |from, to|
      File.write(File.join(dir, "translations", "2-#{from}-#{to}.bluebook"),
                 "Hecks.data_translation \"Shop\", from: \"#{from}\", to: \"#{to}\" do\nend\n")
    end
  end

  def found(*edges, moves: no_moves)
    Dir.mktmpdir("edge-hygiene") do |dir|
      write_edges(dir, edges)
      return hygiene.findings(dir, ledger: ledger, shapes: shapes, moves: moves)
    end
  end

  it "passes a clean chain" do
    expect(found(%w[aaaaaa bbbbbb], %w[bbbbbb cccccc], %w[cccccc dddddd])).to be_empty
  end

  it "does not flag the sole route for a held era" do
    expect(found(%w[aaaaaa dddddd], %w[eeeeee dddddd])).to be_empty
  end

  it "flags a self-loop by file" do
    expect(found(%w[aaaaaa dddddd], %w[aaaaaa aaaaaa]).map { |f| [f.kind, File.basename(f.path)] })
      .to eq([[:self_loop, "2-aaaaaa-aaaaaa.bluebook"]])
  end

  it "tells what to remove for a self-loop" do
    expect(found(%w[aaaaaa aaaaaa]).first.message).to include("git rm ", "2-aaaaaa-aaaaaa.bluebook")
  end

  it "flags an edge that leads away from the current shape as an orphan" do
    expect(found(%w[aaaaaa dddddd], %w[aaaaaa zzzzzz]).map { |f| [f.kind, File.basename(f.path)] })
      .to eq([[:orphan, "2-aaaaaa-zzzzzz.bluebook"]])
  end

  it "flags only the longer branch of a fork" do
    edges = [%w[aaaaaa dddddd], %w[aaaaaa bbbbbb], %w[bbbbbb cccccc], %w[cccccc dddddd]]
    expect(found(*edges).map(&:kind)).to eq([:fork])
  end

  it "names the direct edge to keep and the branch files to remove" do
    edges = [%w[aaaaaa dddddd], %w[aaaaaa bbbbbb], %w[bbbbbb cccccc], %w[cccccc dddddd]]
    expect(found(*edges).first.message).to include("keep aaaaaa -> dddddd", "2-aaaaaa-bbbbbb", "2-cccccc-dddddd")
  end

  it "counts a recorded implicit move as an edge" do
    moves = { "Shop" => [{ "from" => "aaaaaa", "to" => "dddddd" }] }
    expect(found(%w[aaaaaa bbbbbb], %w[bbbbbb dddddd], moves: moves).map(&:kind)).to eq([:fork])
  end

  describe "the known list" do
    around { |example| Dir.mktmpdir("edge-hygiene-check") { |dir| @dir = dir and example.run } }

    def report = hygiene.report(@dir, ledger: {}, shapes: { "Shop" => "aaaaaa1" }, moves: {})

    before { write_edges(@dir, [%w[aaaaaa aaaaaa]]) }

    it "fails on a stale edge it does not list, naming the git rm" do
      expect { report }.to raise_error(Hecks::ShapeLedger::Failure, /git rm .*2-aaaaaa-aaaaaa\.bluebook/)
    end

    it "warns on a listed stale edge and does not fail" do
      File.write(File.join(@dir, hygiene::KNOWN_FILE), '["self_loop:Shop:aaaaaa>aaaaaa"]')
      expect(report).to include("known stale edge")
    end
  end
end

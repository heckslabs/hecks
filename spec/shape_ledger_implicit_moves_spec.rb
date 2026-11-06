require "spec_helper"
require "hecks/shape_ledger"
require "tmpdir"
require "json"

# The shape ledger treats a recorded implicit move as an empty edge: an unrecorded gap is still a
# problem, a recorded move is not, and writing the same move again adds nothing.
RSpec.describe "implicit moves in the shape ledger" do
  let(:held) { { "Shop" => "aaaaaa1" } }
  let(:now) { { "Shop" => "bbbbbb2" } }
  let(:record) { { "Shop" => [{ "from" => "aaaaaa", "to" => "bbbbbb" }] } }

  def problems_with(edges)
    Hecks::ShapeLedger.problems(held, now, edges)
  end

  it "still reports an unrecorded gap with no edge" do
    expect(problems_with(Hecks::ShapeLedger.with_implicit({}, {})).first).to include("with no translation edge")
  end

  it "counts a recorded implicit move as covered" do
    expect(problems_with(Hecks::ShapeLedger.with_implicit({}, record)).first).to include("and an edge covers it")
  end

  it "appends a recorded move once" do
    Dir.mktmpdir("implicit-moves") do |dir|
      path = File.join(dir, Hecks::ShapeLedger::IMPLICIT_FILE)
      2.times { Hecks::ShapeLedger.record_implicit(path, [["Shop", "aaaaaa", "bbbbbb"]]) }
      expect(JSON.parse(File.read(path))).to eq(record)
    end
  end
end

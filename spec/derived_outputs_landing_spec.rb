require "spec_helper"
require "hecks/doc/sources"

# A change lands together with the generated docs that derive from it: the quick gate, which every
# landing runs, holds the tools doc check, and a reworded goal string with no regenerated doc is
# refused by naming the docs it reaches.
RSpec.describe "Derived outputs at landing" do
  let(:root) { InMemoryDomain::ROOT }
  let(:region) { { anchor: "t", kind: "projected", source: "tools:Custodian", assertion: "" } }

  def stage(name) = Hecks::Vocabulary.rows("GateStage").find { |row| row["name"] == name }["checks"].split(",")

  def sources_with(path, from, to)
    committed = lambda do |asked|
      text = File.read(File.join(root, asked))
      asked == path ? text.sub(from, to) : text
    end
    Hecks::Doc::Sources.new(root, committed: committed)
  end

  it "runs the tools doc check in the quick stage as well as the ci stage" do
    expect([stage("quick"), stage("ci")]).to all(include("tools_doc"))
  end

  it "makes the tools doc check compare and never write", :aggregate_failures do
    row = Hecks::Vocabulary.rows("GateCheck").find { |check| check["name"] == "tools_doc" }
    expect(row["argv"]).to include("check.value=true")
    expect(row["blocked"]).to include("docs/tools.md", "cli guides", "commit")
  end

  it "refuses a goal reworded with no regenerated doc, naming the remedy" do
    sources = sources_with("docs/tools.md", "|---|---|\n", "\\0| reworded goal | row |\n")
    expect(sources.drift("docs/tools.md", region)).to include("regeneration_run.project_tools_doc! --confirm")
  end

  it "passes when the doc is as the bluebook renders it" do
    expect(Hecks::Doc::Sources.new(root).drift("docs/tools.md", region)).to be_nil
  end
end

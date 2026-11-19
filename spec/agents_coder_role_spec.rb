require "spec_helper"
require "hecks/tools/agent_roles"

# The coder's brief, read from its `RoleFile` row in the Agents bluebook and from the role file
# generated from it.
module CoderRoleFile
  PATH = File.join(InMemoryDomain::ROOT, ".claude/agents/coder.md")

  def row = Hecks::Tools::AgentRoles::Rows.read(InMemoryDomain::ROOT).find { |each| each[:role] == "coder" }
  def brief = File.read(PATH)
  def steps = row[:steps]
  def handback = row[:handback]
end

# The coder works test-first and behaviour-first: the brief's spec is written and seen to fail
# first, specs speak the domain's words, a golden fixture is never rewritten to pass,
# domain behaviour starts in the bluebook, locally only the work item's own specs and the quick
# gate run, and a branch is done only when the spec it added went from red to green and CI is
# green on its tip.
RSpec.describe "the coder's brief" do
  include CoderRoleFile

  it "is the role file generated from the bluebook's coder row" do
    expect(brief).to eq(Hecks::Tools::AgentRoles::Render.text(row))
  end

  it "has the coder write the brief's spec first and see it fail for the stated reason", :aggregate_failures do
    expect(steps).to include("write the spec the brief names", "see it fail for the reason the brief states")
    expect(steps).to include("as the branch's first commit", "Report both outputs")
  end

  it "asks that a spec state behaviour in the domain's words" do
    expect(steps).to include("states behaviour in the domain's words")
  end

  it "forbids rewriting a golden fixture or snapshot to pass unless the brief says that output changes" do
    expect(steps).to include("Never rewrite a golden fixture or a snapshot to make a spec pass unless the brief says")
  end

  it "puts the bluebook and its .behaviors first for domain behaviour" do
    expect(steps).to include("the bluebook and its `.behaviors` file come first")
  end

  it "runs locally only the work item's own specs and the quick gate, leaving the rest to CI", :aggregate_failures do
    expect(steps).to include("only the work item's own specs and the quick gate", "CI runs the rest", "EarlyCi.request!")
    expect(brief).not_to include("cap.value=200")
  end

  it "counts a branch done only when its spec failed before the fix, passes, and gate and CI are green" do
    expect(handback).to include("the spec failed before the fix and passes on the branch, " \
                                "the quick gate is green and CI passed on its tip")
  end
end

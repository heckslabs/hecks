require "spec_helper"

# The architect's rubric holds the Hecks modeling (M) and Hecks craft (C) lenses, each rule with a
# test, a smell and a construct, and the architect's role names both lenses in its steps.
RSpec.describe "the architecture review rubric" do
  let(:root)   { InMemoryDomain::ROOT }
  let(:rubric) { File.read(File.join(root, "docs/ARCHITECTURE_REVIEW.md")) }
  let(:steps)  { File.read(File.join(root, "lib/hecks/agents/agents.bluebook")) }

  def rule(id) = rubric[/^- \*\*#{id}\b.*?(?=^- \*\*|^## )/m].to_s

  it "holds a rule for each of M1 to M4 and C1 to C11" do
    ids = (1..4).map { |n| "M#{n}" } + (1..11).map { |n| "C#{n}" }
    expect(ids.reject { |id| rule(id).include?("Test:") }).to be_empty
  end

  it "gives each modeling rule a smell and a construct" do
    expect((1..4).reject { |n| rule("M#{n}").include?("Smell:") && rule("M#{n}").include?("Use ") }).to be_empty
  end

  it "cites the ADRs of the four modeling patterns" do
    cited = rubric.scan(/ADRs? ((?:\d{4}(?:, |, and | and )?)+)/).flatten.join(" ").scan(/\d{4}/)
    expect(cited).to include("0180", "0067", "0040", "0061", "0050", "0052", "0055", "0078", "0079")
  end

  it "points at repo examples that exist" do
    paths = rubric.scan(%r{`(lib/hecks/[\w/.]+\.(?:bluebook|hecksagon))`}).flatten.uniq
    expect(paths.reject { |path| File.exist?(File.join(root, path)) }).to be_empty
  end

  it "names the lenses in the architect's steps" do
    expect(steps).to include("five lenses", "Hecks modeling (M", "Hecks craft (C", "Read the best example")
  end

  it "gives every smell the seeded bad plans need" do
    smells = ["policies chained", "primitive", "polling", "hidden in a command", "no port `asks`",
              "conditional on domain meaning"]
    expect(smells.reject { |smell| rubric.include?(smell) }).to be_empty
  end
end

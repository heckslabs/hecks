require "spec_helper"
require "yaml"
require "hecks/tools"
require "hecks/tools/attested_checks"

# Which checks a signed note may stand in for is declared on the GateCheck and RequiredCheck rows of
# the Vocabulary bluebook. The pre-push hook, ci.yml's two note writers and every workflow step that
# skips on a note read it from there, so a note never vouches for a check the rows did not name.
RSpec.describe Hecks::Tools::AttestedChecks do
  let(:root) { Hecks::Tools::ROOT }

  def workflow(name) = YAML.load_file(File.join(root, ".github/workflows", name))

  def workflows = Dir[File.join(root, ".github/workflows/*.yml")].map { |path| YAML.load_file(path) }

  def steps_using(action)
    workflows.flat_map { |file| file.fetch("jobs").values }
             .flat_map { |job| job.fetch("steps", []) }
             .select { |step| step["uses"].to_s.end_with?(action) }
  end

  def named_by(step) = step.dig("with", "checks").split(",")

  it "marks only checks the pre_push stage runs, since the hook vouches for nothing else" do
    expect(described_class.unrun_in("pre_push")).to eq([])
  end

  it "marks the four checks the hook has always vouched for" do
    expect(described_class.local).to contain_exactly("doc_coverage", "engine_agreement", "model_check", "rubocop")
  end

  it "leaves release_consistency out, since a release bump reruns it" do
    expect(described_class.ci).not_to include("release_consistency")
  end

  it "writes the note ci.yml holds in both of its writers from the rows", :aggregate_failures do
    writers = steps_using("write-attestation")

    expect(writers.size).to eq(2)
    expect(writers.map { |step| named_by(step) }).to all(eq(described_class.ci))
  end

  it "has no workflow step that reads a note for a name the rows do not declare" do
    asked = steps_using("check-attestation").flat_map { |step| named_by(step) }.uniq

    expect(asked - described_class.ci).to eq([])
  end

  it "skips on a note only the ci stage checks the rows mark as attestable", :aggregate_failures do
    steps = workflow("ci-checks.yml").fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }
    skipping = steps.select { |step| step["if"].to_s.include?("steps.attest.outputs.attested") }
    ran = skipping.flat_map { |step| step["run"].to_s[/only=(\S+)/, 1].to_s.split(",") }

    expect(ran).not_to be_empty
    expect(ran - described_class.local).to eq([])
  end

  it "keeps the check names out of the hook, which reads them from pre-push.lanes", :aggregate_failures do
    table = File.read(File.join(root, ".githooks/pre-push.lanes"))

    expect(File.read(File.join(root, ".githooks/pre-push"))).not_to include("doc_coverage")
    expect(table).to include("@attests #{described_class.local.join(",")}")
  end
end

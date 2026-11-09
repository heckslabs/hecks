require "spec_helper"
require "yaml"
require "hecks/tools"
require "hecks/tools/attested_checks"

# Which checks a signed note may stand in for is declared on the GateCheck and RequiredCheck rows of
# the Vocabulary bluebook. The pre-push hook and ci.yml's two note writers hold regions the rows
# write, and every workflow step that reads or skips on a note is held to the declared names here:
# this spec is the only link to the hand-written `check-attestation` inputs, ci-rspec.yml's
# CiWorkflows row among them, so a note never vouches for a check the rows did not name.
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

  def gate_rows = Hecks::Vocabulary.rows("GateCheck").select { |row| row["attests"] == "yes" }

  it "marks only checks the pre_push stage runs, since the hook vouches for nothing else" do
    expect(described_class.unrun_in("pre_push")).to eq([])
  end

  it "marks no check that only CI runs, since the hook never ran it" do
    expect(gate_rows.map { |row| row["runs_in"] }).not_to include("ci")
  end

  it "marks the four checks the hook has always vouched for" do
    expect(described_class.local).to contain_exactly("doc_coverage", "engine_agreement", "model_check", "rubocop")
  end

  it "leaves release_consistency out, since a release bump reruns it" do
    expect(described_class.ci).not_to include("release_consistency")
  end

  it "names the checks sum by its jobs, never by its own name", :aggregate_failures do
    expect(described_class.ci).not_to include("checks")
    expect(described_class.ci).to include(*described_class::JOBS_UNDER.fetch("checks"))
  end

  it "writes the note ci.yml holds in both of its writers from the rows", :aggregate_failures do
    writers = steps_using("write-attestation")

    expect(writers.size).to eq(2)
    expect(writers.map { |step| named_by(step) }).to all(match_array(described_class.ci))
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

  it "writes the hook's one ATTEST_CHECKS line inside its region, from the rows", :aggregate_failures do
    hook = File.read(File.join(root, ".githooks/pre-push"))
    region = hook[described_class::REGION]

    expect(hook.scan(/^\s*ATTEST_CHECKS=/).size).to eq(1)
    expect(region).to include("ATTEST_CHECKS=\"#{described_class.local.join(",")}\"")
  end

  it "refuses a file that should hold a region and does not", :aggregate_failures do
    expect { described_class.write("checks: rspec\n", ".githooks/pre-push") }
      .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      .and output(%r{\.githooks/pre-push has no BEGIN/END GENERATED attested_checks region}).to_stderr
  end

  it "leaves a file with no region alone when none is required" do
    expect(described_class.write("checks: rspec\n", ".github/workflows/ci-rspec.yml")).to eq("checks: rspec\n")
  end
end

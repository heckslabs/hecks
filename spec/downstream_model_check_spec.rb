require "spec_helper"
require "tmpdir"
require "yaml"
require "hecks/tools/downstream_model_check"

# The model check a domain repository runs is generated from Hecks, so the text is one function of
# the domain directory, a checkout written from it is current, and a hand edit is reported as drift.
RSpec.describe Hecks::Tools::DownstreamModelCheck do
  let(:root) { Dir.mktmpdir("downstream-model-check-") }
  let(:path) { File.join(root, described_class::FILE) }

  after { FileUtils.rm_rf(root) }

  def run(check: false)
    described_class.main(root: root, domain_directory: "domain/emaho", check: check)
  end

  it "runs the client-profile model check over the bluebooks in the domain directory", :aggregate_failures do
    workflow = YAML.load(described_class.workflow(domain_directory: "domain/emaho"))
    step = workflow.dig("jobs", "model-check", "steps").find { |s| s["name"]&.start_with?("Model check") }

    expect(step["working-directory"]).to eq("domain/emaho")
    expect(step["run"]).to include("model_check_run.model_check! profile=client domains=bluebook --wait")
  end

  it "writes the workflow when the checkout has none", :aggregate_failures do
    expect(run).to eq(0)
    expect(File.read(path)).to eq(described_class.workflow(domain_directory: "domain/emaho"))
  end

  it "answers current for a checkout written from the generator" do
    run
    expect(run(check: true)).to eq(0)
  end

  it "answers out of date for a hand-edited workflow" do
    run
    File.write(path, File.read(path).sub("profile=client", "profile=full"))

    expect(run(check: true)).to eq(1)
  end
end

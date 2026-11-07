require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/coder_job_facts"

# The facts a job read carries for the coder: git is read only for a coder's finished job, and a
# checkout that is not there answers empty facts, which Submit refuses, instead of failing the read.
RSpec.describe Hecks::Adapters::CoderJobFacts do
  subject(:facts) { described_class.new(git: git) }

  let(:git) { instance_double(Hecks::Adapters::Git) }

  before { allow(git).to receive(:capture) }

  it "reads no git for a job that is still working" do
    facts.call(agent: "coder", state: "working", report: "", checkout: Dir.tmpdir)
    expect(git).not_to have_received(:capture)
  end

  it "answers the agent and report alone for another agent" do
    expect(facts.call(agent: "architect", state: "done", report: "submitted", checkout: Dir.tmpdir))
      .to eq(agent: "architect", report: "submitted")
  end

  it "answers empty facts for a checkout that is not there" do
    expect(facts.call(agent: "coder", state: "done", report: "submitted", checkout: "/no/such/checkout"))
      .to include(branch: "", sha: "", clean: false)
  end
end

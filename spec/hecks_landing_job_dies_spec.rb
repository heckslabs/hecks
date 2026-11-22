require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "tmpdir"
require "open3"
require "rbconfig"

# A landing job that ends with neither BranchLanded nor LandingRefused recorded reports it: it
# abandons the landing, once, naming the branch and the last line of the log. Each example runs the
# job's own script against a stand-in launcher, so no landing runs.
RSpec.describe Hecks::Adapters::GitLanding::Job, "when the carry dies" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-dies")) }
  let(:calls) { File.join(dir, "calls") }
  let(:log) { File.join(dir, "job.log") }
  let(:launcher) { File.join(dir, "hecks") }

  after { FileUtils.remove_entry(dir) }

  def launcher_says(output)
    File.write(launcher, "#!/bin/sh\necho \"${HECKS_NO_RESIDENT:-resident} $*\" >> #{calls}\n#{output}\nexit 1\n")
    File.chmod(0o755, launcher)
  end

  def run_job
    carry = ["Landing.carry!", "branch.value=work/a", "--confirm"]
    Open3.capture2e(RbConfig.ruby, "-e", described_class::SCRIPT, launcher, dir, "1", "0", *carry, log)
    File.readlines(calls)
  end

  def abandons = run_job.grep(/Landing.abandon!/)

  it "abandons the landing once, naming the branch and the line the carry died on", :aggregate_failures do
    launcher_says("echo 'hecks: the resident went away while this line ran; its status is unknown' >&2")
    found = abandons

    expect(found.size).to eq(1)
    expect(found.first).to include("branch.value=work/a", "the resident went away")
  end

  it "runs a carry whose resident went away once more without the resident" do
    launcher_says("echo 'hecks: the resident went away while this line ran; its status is unknown' >&2")

    expect(run_job.grep(/Landing.carry!/).map { |line| line.split.first }).to eq(%w[resident 1])
  end

  it "abandons nothing when the carry recorded a refusal" do
    launcher_says("echo '\"events\": [\"CarryRequested\", \"LandingRefused\"]'")

    expect(abandons).to be_empty
  end
end

require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
require "hecks/hecks/adapters/landing/reporting_job"
require "tmpdir"
require "open3"
require "rbconfig"

# Runs a landing job's own script against a stand-in launcher that records each call it is given.
module LandingJobDiesHelpers
  WENT = "echo 'hecks: the resident went away while this line ran; its status is unknown' >&2".freeze

  def launcher_says(output)
    launcher = File.join(dir, "hecks")
    calls = File.join(dir, "calls")
    File.write(launcher, "#!/bin/sh\necho \"${HECKS_NO_RESIDENT:-resident} $*\" >> #{calls}\n#{output}\nexit 1\n")
    File.chmod(0o755, launcher)
  end

  def started_script
    exe = File.join(dir, "exe", "hecks")
    FileUtils.mkdir_p(File.dirname(exe))
    File.write(exe, "")
    FileUtils.chmod(0o755, exe)
    spawned = []
    Hecks::Adapters::GitLanding::Job.new(dir, spawner: ->(argv, _from) { spawned << argv }, logs: dir)
                                    .start(checkout: dir, branch: "b", onto: "main")
    spawned.first[2]
  end

  def run_job
    argv = [RbConfig.ruby, "-e", Hecks::Adapters::Landing::ReportingJob::SCRIPT, File.join(dir, "hecks"), dir, "1", "0",
            "Landing.carry!", "branch.value=work/a", "--confirm", File.join(dir, "job.log")]
    Open3.capture2e({ "HECKS_NO_RESIDENT" => nil }, *argv)
    File.readlines(File.join(dir, "calls"))
  end
end

# A landing job that ends with neither BranchLanded nor LandingRefused recorded reports it: it
# records a LandingJobFault, once, naming the branch and the last line of the log.
RSpec.describe "a landing job whose carry dies" do
  include LandingJobDiesHelpers

  let(:dir) { File.realpath(Dir.mktmpdir("hecks-landing-dies")) }

  after { FileUtils.remove_entry(dir) }

  it "records one fault naming the branch and the line the carry died on", :aggregate_failures do
    launcher_says(LandingJobDiesHelpers::WENT)
    found = run_job.grep(/LandingJobFault.report!/)

    expect(found.size).to eq(1)
    expect(found.first).to include("branch.value=work/a", "the resident went away")
  end

  it "runs a carry whose resident went away once more without the resident" do
    launcher_says(LandingJobDiesHelpers::WENT)

    expect(run_job.grep(/Landing.carry!/).map { |line| line.split.first }).to eq(%w[resident 1])
  end

  it "records nothing when the carry recorded a refusal" do
    launcher_says("echo '\"events\": [\"CarryRequested\", \"LandingRefused\"]'")

    expect(run_job.grep(/LandingJobFault/)).to be_empty
  end

  it "is the script a started job runs" do
    expect(started_script).to include("LandingJobFault.report!")
  end
end

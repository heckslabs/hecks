require "spec_helper"
require "json"
require "tmpdir"
require "hecks/hecks/adapters/claude_jobs"

# The wait after a resume: the answer is held while the woken session's job still reads `stopped`,
# and at most for the patience.
RSpec.describe Hecks::Adapters::ClaudeJobs do
  let(:directory) { Dir.mktmpdir("claude-jobs") }
  let(:resumed) { { session: { value: "s1" } } }

  after { FileUtils.rm_rf(directory) }

  def job(state)
    FileUtils.mkdir_p(File.join(directory, "s1"))
    File.write(File.join(directory, "s1", "state.json"), JSON.generate(state: state))
  end

  def jobs(patience) = described_class.new(directory: directory, wake_patience: patience, pause: 0.01)

  def seconds
    began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - began
  end

  it "answers at once when the job reads working", :aggregate_failures do
    job("working")

    expect(seconds { expect(jobs(5).woken(resumed)).to eq(resumed) }).to be < 1
  end

  it "answers at once when the woken session has already ended" do
    job("done")

    expect(seconds { jobs(5).woken(resumed) }).to be < 1
  end

  it "answers at once for a job that is not written yet, as a copy's is not" do
    expect(seconds { jobs(5).woken(resumed) }).to be < 1
  end

  it "waits while the job still reads stopped, and answers once the session wrote its state", :aggregate_failures do
    job("stopped")
    waiting = jobs(5)
    allow(waiting).to receive(:sleep) { job("working") }

    expect(waiting.woken(resumed)).to eq(resumed)
    expect(waiting).to have_received(:sleep).once
  end

  it "gives up after the patience and answers anyway" do
    job("stopped")

    expect(seconds { jobs(0.1).woken(resumed) }).to be_between(0.1, 2)
  end
end

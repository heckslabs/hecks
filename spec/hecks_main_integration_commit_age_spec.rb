require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration"

# The time a run's landed commit was committed is read from the checkout it landed in; a run with
# no readable checkout has none, so it is never taken for stale.
RSpec.describe Hecks::Adapters::MainIntegration::CommitAge do
  let(:run) { Hecks::Adapters::MainIntegration::Runs::Run }

  def commit_in(dir)
    system("git", "init", "-q", dir)
    system({ "GIT_COMMITTER_DATE" => "2026-11-16T03:34:00Z" }, "git", "-C", dir, "-c", "user.name=a",
           "-c", "user.email=a@b.c", "commit", "-q", "--allow-empty", "-m", "x")
    IO.popen(["git", "-C", dir, "rev-parse", "HEAD"], &:read).strip
  end

  it "reads the committer time of the landed commit in its checkout" do
    Dir.mktmpdir do |dir|
      held = run.new(commit_in(dir), "ci_running", dir)
      expect(described_class.new.committed(held)).to eq(Time.utc(2026, 11, 16, 3, 34))
    end
  end

  it "answers nothing when the run has no checkout" do
    expect(described_class.new.committed(run.new("a" * 40, "ci_running", ""))).to be_nil
  end
end

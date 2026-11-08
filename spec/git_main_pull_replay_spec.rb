require "spec_helper"
require "hecks/hecks/adapters/git_main_pull"
require "hecks/hecks/adapters/shell"

# A rebase that stops with no file in conflict says why in git's words, and one run on a machine
# that names no committer borrows the tip commit's.
RSpec.describe Hecks::Adapters::GitMainPull::Replay do
  let(:status) { instance_double(Process::Status, success?: true) }
  let(:git) { instance_double(Hecks::Adapters::Git) }
  let(:replayer) do
    host = git
    Class.new do
      include Hecks::Adapters::GitMainPull::Replay

      public :replay_identity, :abandon_rebase

      define_method(:initialize) { @git = host }
    end.new
  end

  def result(out, err = "") = Hecks::Adapters::Shell::Result.new(out, err, status)

  def answer(*args, out)
    allow(git).to receive(:capture).with(*args, chdir: "/w").and_return(result(out))
  end

  it "reports git's own message when no file is in conflict" do
    answer("diff", "--name-only", "--diff-filter=U", "")
    answer("rebase", "--abort", "")
    failed = result("", "fatal: unable to auto-detect email address")
    expect(replayer.abandon_rebase("/w", failed)).to eq("failed: fatal: unable to auto-detect email address")
  end

  it "names the files when some are in conflict" do
    answer("diff", "--name-only", "--diff-filter=U", "a.txt\nb.txt\n")
    answer("rebase", "--abort", "")
    expect(replayer.abandon_rebase("/w", result("", "boom"))).to eq("conflicts in a.txt, b.txt")
  end

  it "borrows the tip commit's committer when none is configured" do
    answer("config", "user.email", "")
    answer("log", "-1", "--format=%cn%n%ce", "Ann\nann@x\n")
    expect(replayer.replay_identity("/w")).to eq(%w[-c user.name=Ann -c user.email=ann@x])
  end

  it "adds nothing when an identity is configured" do
    answer("config", "user.email", "me@x\n")
    expect(replayer.replay_identity("/w")).to eq([])
  end
end

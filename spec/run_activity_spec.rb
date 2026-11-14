require "spec_helper"
require "hecks/hecks/adapters/run_activity"

# Signs of life for a started run. A run that works in the checkout's own root has no signs of
# its own: every hecks process names that directory, and its commits and changes belong to
# whoever works there. Only the session id, or a linked worktree, can show the run is alive.
RSpec.describe Hecks::Adapters::RunActivity do
  let(:root) { "/Users/me/Projects/hecks" }
  let(:tree) { "#{root}/.claude/worktrees/some-item" }
  let(:said) { Struct.new(:out, :ok?) }
  let(:shell) { instance_double(Hecks::Adapters::Shell) }
  let(:activity) { described_class.new(shell: shell) }

  def ps(*lines) = allow(shell).to receive(:capture).with("ps", "-axo", "command").and_return(said.new(lines.join("\n"), true))

  it "sees a process that names the session id" do
    ps("claude --session-id abc123 --bg")

    expect(activity.process?("abc123", root)).to be(true)
  end

  it "does not take a process naming the checkout's root for a sign of life" do
    ps("#{root}/exe/hecks Board.serve!", "ruby -I #{root}/lib resident/server")

    expect(activity.process?("abc123", root)).to be(false)
  end

  it "takes a process naming a linked worktree for a sign of life" do
    ps("ruby #{tree}/exe/hecks test_suite_run.run_spec_files!")

    expect(activity.process?("abc123", tree)).to be(true)
  end

  it "reads no commit or change in the checkout's own root" do
    expect(activity.last_at(Dir.tmpdir)).to be_nil
  end
end

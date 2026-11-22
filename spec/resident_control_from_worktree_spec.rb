require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/adapters/driving/resident/client"
require "hecks/adapters/driving/resident/control"

# A control command (tickets, messages, settings, the red flag's status) acts on the primary
# checkout's shared stores, so a launcher in a linked worktree with no resident of its own asks the
# primary checkout's resident instead of booting cold. Every other line asks only its own checkout.
RSpec.describe "a control command run from a linked worktree" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:client) { resident::Client }
  let(:dir) { Dir.mktmpdir("control") }
  let(:primary) { File.join(dir, "primary") }
  let(:worktree) { File.join(primary, ".claude", "worktrees", "topic") }
  let(:own_script) { File.join(worktree, "exe", "hecks") }
  let(:primary_script) { File.join(primary, "exe", "hecks") }

  before do
    [primary_script, own_script].each { |path| FileUtils.mkdir_p(File.dirname(path)) && FileUtils.touch(path) }
    admin = File.join(primary, ".git", "worktrees", "topic")
    FileUtils.mkdir_p(admin)
    File.write(File.join(admin, "commondir"), "../..\n")
    File.write(File.join(worktree, ".git"), "gitdir: #{admin}\n")
    stub_const("ARGV", ["tickets", "Work.undone"])
    allow(resident::Paths).to receive(:recall_words).with("control").and_return(%w[work message dial redflag.status])
    allow(client).to receive(:spawn_resident).and_return("started")
  end

  after { FileUtils.rm_rf(dir) }

  def own_has_none = allow(client).to receive(:ask).with(File.realpath(worktree), anything).and_return([nil, nil])

  it "finds the primary checkout from the worktree's own .git file" do
    expect(resident::Control.primary_root(File.realpath(worktree))).to eq(File.realpath(primary))
  end

  it "has no primary for a checkout of its own" do
    expect(resident::Control.primary_root(File.realpath(primary))).to be_nil
  end

  it "is served by the primary's resident, asked with the primary's launcher" do
    own_has_none
    allow(client).to receive(:ask).with(File.realpath(primary), File.join(File.realpath(primary), "exe", "hecks")).and_return([0, nil])
    expect { client.attempt(File.realpath(worktree), own_script) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
  end

  it "says on stderr that the primary's code served it" do
    own_has_none
    allow(client).to receive(:ask).with(File.realpath(primary), anything).and_return([0, nil])
    expect { client.attempt(File.realpath(worktree), own_script) rescue nil }
      .to output(/served by the primary checkout's resident/).to_stderr
  end

  it "boots cold, and says why, when the primary's resident refuses the line" do
    own_has_none
    allow(client).to receive(:ask).with(File.realpath(primary), anything).and_return([nil, "overlay:cwd"])
    expect(client.attempt(File.realpath(worktree), own_script)).to eq("refused:via-primary:overlay:cwd")
  end

  it "boots cold when the primary has no resident, and starts none for the primary" do
    allow(client).to receive(:ask).and_return([nil, nil])
    client.attempt(File.realpath(worktree), own_script)
    expect(client).to have_received(:spawn_resident).with(File.realpath(worktree), own_script)
  end

  it "asks only its own checkout for a line that is not a control command" do
    stub_const("ARGV", ["style", "StyleRun.check_comments!"])
    own_has_none
    client.attempt(File.realpath(worktree), own_script)
    expect(client).not_to have_received(:ask).with(File.realpath(primary), anything)
  end

  it "asks only its own checkout when no control words were written" do
    allow(resident::Paths).to receive(:recall_words).with("control").and_return([])
    own_has_none
    client.attempt(File.realpath(worktree), own_script)
    expect(client).not_to have_received(:ask).with(File.realpath(primary), anything)
  end

  it "does not ask the primary when the worktree's own resident refused the line" do
    allow(client).to receive(:ask).with(File.realpath(worktree), anything).and_return([nil, "env:GEM_HOME"])
    expect(client.attempt(File.realpath(worktree), own_script)).to eq("refused:env:GEM_HOME")
  end
end

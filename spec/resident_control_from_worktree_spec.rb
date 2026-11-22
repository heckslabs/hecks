require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/adapters/driving/resident/client"
require "hecks/adapters/driving/resident/control"
require "hecks/adapters/driving/resident/stuck"

# A control command (tickets, messages, settings, the red flag's status) acts on the primary
# checkout's shared stores, so a launcher in a linked worktree with no resident of its own asks the
# primary checkout's resident instead of booting cold. Every other line asks only its own checkout.
RSpec.describe "a control command run from a linked worktree" do
  let(:client) { Hecks::Adapters::Driving::Resident::Client }
  let(:control) { Hecks::Adapters::Driving::Resident::Control }
  let(:dir) { Dir.mktmpdir("control") }
  let(:primary) { File.realpath(File.join(dir, "primary")) }
  let(:worktree) { File.join(primary, ".claude", "worktrees", "topic") }

  before do
    build_checkouts
    stub_const("ARGV", ["tickets", "Work.undone"])
    allow(Hecks::Adapters::Driving::Resident::Paths).to receive(:recall_words)
      .with("control").and_return(%w[work message dial redflag.status])
    allow(Hecks::Adapters::Driving::Resident::Stuck).to receive(:after)
    allow(client).to receive(:spawn_resident).and_return("started")
  end

  after { FileUtils.rm_rf(dir) }

  def build_checkouts
    FileUtils.mkdir_p([File.join(dir, "primary", "exe"), File.join(dir, "primary", ".claude", "worktrees", "topic")])
    FileUtils.touch(File.join(dir, "primary", "exe", "hecks"))
    admin = File.join(dir, "primary", ".git", "worktrees", "topic")
    FileUtils.mkdir_p(admin)
    File.write(File.join(admin, "commondir"), "../..\n")
    File.write(File.join(worktree, ".git"), "gitdir: #{admin}\n")
  end

  def own = File.realpath(worktree)

  def launch = client.attempt(own, File.join(own, "exe", "hecks"))

  def ending
    yield
  rescue SystemExit => e
    e.status
  end

  def primary_answers(answer)
    allow(client).to receive(:ask).with(own, anything).and_return([nil, nil])
    allow(client).to receive(:ask).with(primary, File.join(primary, "exe", "hecks")).and_return(answer)
  end

  it "finds the primary checkout from the worktree's own .git file" do
    expect(control.primary_root(own)).to eq(primary)
  end

  it "has no primary for a checkout of its own" do
    expect(control.primary_root(primary)).to be_nil
  end

  it "is served by the primary's resident, asked with the primary's launcher" do
    primary_answers([0, nil])
    expect(ending { launch }).to eq(0)
  end

  it "says on stderr that the primary's code served it" do
    primary_answers([0, nil])
    expect { ending { launch } }.to output(/served by the primary checkout's resident/).to_stderr
  end

  it "boots cold, and says why, when the primary's resident refuses the line" do
    primary_answers([nil, "overlay:cwd"])
    expect(launch).to eq("refused:via-primary:overlay:cwd")
  end

  it "boots cold when the primary has no resident, and starts none for the primary" do
    allow(client).to receive(:ask).and_return([nil, nil])
    launch
    expect(client).to have_received(:spawn_resident).with(own, File.join(own, "exe", "hecks"))
  end

  it "asks only its own checkout for a line that is not a control command" do
    stub_const("ARGV", ["style", "StyleRun.check_comments!"])
    primary_answers([0, nil])
    launch
    expect(client).not_to have_received(:ask).with(primary, anything)
  end

  it "asks only its own checkout when no control words were written" do
    allow(Hecks::Adapters::Driving::Resident::Paths).to receive(:recall_words).with("control").and_return([])
    primary_answers([0, nil])
    launch
    expect(client).not_to have_received(:ask).with(primary, anything)
  end

  it "does not ask the primary when the worktree's own resident refused the line" do
    allow(client).to receive(:ask).with(own, anything).and_return([nil, "env:GEM_HOME"])
    expect(launch).to eq("refused:env:GEM_HOME")
  end
end

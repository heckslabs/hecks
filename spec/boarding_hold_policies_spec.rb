require "spec_helper"
require "hecks/hecks/adapters/git_rehearsal"
require "hecks/hecks/adapters/boarding_hold_marker"
require "fileutils"
require "open3"
require "tmpdir"

# The policies of the BoardingHold bluebook: a deep rehearsal holds main, a green one keeps the hold
# until the boarding, a red one and a refused boarding lift it, and a quick rehearsal never holds.
# The stages are stubbed and the repository is a throwaway one.
RSpec.describe Hecks::Adapters::GitRehearsal, "#trial" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-boarding-hold-policies")) }
  let(:repo) { File.join(dir, "main") }
  let(:passed) { Hecks::Adapters::GitRehearsal::Stages::Result.new("quick", true, "") }
  let(:failed) { Hecks::Adapters::GitRehearsal::Stages::Result.new("quick", false, "no") }
  let(:stages) { instance_double(Hecks::Adapters::GitRehearsal::Stages, run: [passed]) }

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    git("commit", "--allow-empty", "-m", "first")
    allow(Hecks::Adapters::GitRehearsal::Stages).to receive(:new).and_return(stages)
  end

  after { FileUtils.remove_entry(dir) }

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: repo)
    raise out unless status.success?

    out
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Dir.chdir(repo) { Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks") }
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def rehearse(scope)
    launch("push_rehearsal.rehearse!", "run=r-#{SecureRandom.hex(4)}", "checkout.value=#{repo}", "scope.value=#{scope}", "--wait")
  end

  def rehearse_here(scope)
    launch("push_rehearsal.rehearse!", "run=r-#{SecureRandom.hex(4)}", "scope.value=#{scope}", "--wait")
  end

  def held? = File.exist?(File.join(repo, ".git", Hecks::Adapters::BoardingHoldMarker::FILE))

  it "holds main during a deep rehearsal that ends green" do
    rehearse("deep")

    expect(held?).to be(true)
  end

  it "holds main for a deep rehearsal that names no checkout" do
    rehearse_here("deep")

    expect(held?).to be(true)
  end

  it "lifts the hold when a deep rehearsal ends red" do
    allow(stages).to receive(:run).and_return([failed])
    rehearse("deep")

    expect(held?).to be(false)
  end

  it "does not hold main for a quick rehearsal" do
    rehearse("quick")

    expect(held?).to be(false)
  end

  it "lifts the hold when the boarding is refused" do
    rehearse("deep")
    absent = File.join(dir, "absent")
    launch("send_train.board!", "run=b-#{SecureRandom.hex(4)}", "checkout.value=#{absent}", "--confirm", "--wait")

    expect(held?).to be(false)
  end
end

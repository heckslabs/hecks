require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

# The events of the pusher lock, through the launcher in Memory over a throwaway repository:
# PusherAssigned for each assignment, BoardingRefused for a boarding by a session that is not the
# pusher. Nothing reaches the real .git, ~/.claude or a remote.
RSpec.describe "the pusher lock's events" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-pusher-events")) }
  let(:repo) { File.join(dir, "work") }

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false,
                                                                            environment:     HecksMemoryEnvironment::NAME)
  end

  before do
    @hecks.registry.event_log.clear
    git("init", "-q", "-b", "main", repo, chdir: dir)
    git("commit", "--allow-empty", "-q", "-m", "start")
  end

  after do
    ENV["CLAUDE_JOB_DIR"] = @job
    FileUtils.remove_entry(dir)
  end

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  def assign(session) = launch("Pusher.assign!", "session.value=#{session}", "checkout.value=#{repo}", "--wait")

  def names = @hecks.registry.event_log.map(&:name)

  def as_session(id)
    @job = ENV.fetch("CLAUDE_JOB_DIR", nil)
    ENV["CLAUDE_JOB_DIR"] = "/jobs/#{id}"
  end

  it "emits PusherAssigned each time the pusher is assigned", :aggregate_failures do
    assign("s1")
    assign("s2")

    expect(names.count("PusherAssigned")).to eq(2)
    expect(File.read(File.join(repo, ".git", "hecks-pusher"))).to eq("s2\n")
  end

  it "emits BoardingRefused with the named reason when another session boards", :aggregate_failures do
    assign("s1")
    as_session("s2")
    launch("SendTrain.board!", "checkout.value=#{repo}", "--confirm", "--wait")

    expect(names).to include("BoardingRefused")
    expect(refusal_reason).to end_with("only the pusher boards: s1")
  end

  def refusal_reason
    event = @hecks.registry.event_log.reverse.find { |logged| logged.name == "BoardingRefused" }
    Hecks::Runtime::Value.materialize(event.payload).dig(:reason, :value)
  end
end

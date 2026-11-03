require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/hecks/adapters/red_flagging"
require "hecks/hecks/adapters/red_flag_guard"
require "hecks/pipeline_board/adapters/pipeline_web/flag_watch"

# The red flag driver: a red CI run of main raises the flag once per head, a green run lowers it,
# the status names the marker file, and the board's sync runs `RedFlag.sync!` through the launcher.
# Every example builds its own repository under a temporary directory and stubs GitHub.
RSpec.describe "The red flag driver" do
  let(:dir) { Dir.mktmpdir("hecks-red-flag-driver-spec") }
  let(:repo) { File.join(dir, "repo") }
  let(:runs) { [] }
  let(:flagging) { Hecks::Adapters::RedFlagging.new(checkout: repo, runner: ->(argv, **) { gh(argv) }) }

  after { FileUtils.remove_entry(dir) }

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    git("commit", "--allow-empty", "-m", "first")
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: repo)
    raise out unless status.success?

    out
  end

  # A fake GitHub: the run list answers `runs`; a run view answers one failed job.
  def gh(argv)
    return [true, JSON.generate(runs)] if argv[1] == "run" && argv[2] == "list"

    [true, JSON.generate("jobs" => [{ "name" => "tests", "conclusion" => "failure" }])]
  end

  def run(id, conclusion, sha = git("rev-parse", "HEAD").strip)
    { "databaseId" => id, "status" => "completed", "conclusion" => conclusion, "headSha" => sha }
  end

  # Replaces the CI runs GitHub reports, then reads main's newest run as `RedFlag.sync!` does.
  def sync(list)
    runs.replace(list)
    flagging.survey
  end

  def outcome(answer) = answer.dig(:outcome, :value)

  def marker_path = File.join(repo, ".git", "hecks-red-flag.json")

  def marker_runs = JSON.parse(File.read(marker_path)).fetch("runs")

  def status_of(success) = Struct.new(:success?).new(success)

  # A launcher stand-in that records each call and answers success.
  def launcher(calls)
    lambda do |*argv, chdir:|
      calls << [argv, chdir]
      ["", status_of(true)]
    end
  end

  it "raises the flag on a red run of main, and not again for the same head", :aggregate_failures do
    expect(outcome(sync([run(7, "failure")]))).to eq("raised")
    expect(outcome(sync([run(8, "failure")]))).to eq("idle")
  end

  it "records one sighting of a red head on the flag", :aggregate_failures do
    sync([run(7, "failure")])
    sync([run(8, "failure")])

    expect(marker_runs.map { |sighting| sighting["ci_run"] }).to eq(["7"])
  end

  it "lowers the flag on a green run of main and removes the marker" do
    sync([run(7, "failure")])

    expect(outcome(sync([run(9, "success")]))).to eq("cleared")
  end

  it "reports the standing flag and the marker file it is kept in", :aggregate_failures do
    sync([run(7, "failure")])
    text = flagging.status[:text]

    expect(text).to include("main is red")
    expect(text).to include("hecks-red-flag.json")
  end

  it "refuses a landing that is not a red Work item's fix while the flag stands" do
    sync([run(7, "failure")])
    guard = Hecks::Adapters::RedFlagGuard.new(File.join(repo, ".git"))

    expect { guard.landing!("feature/search") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /main is red: flag flag-/)
  end

  it "runs RedFlag.sync! through the checkout's launcher, once per tick", :aggregate_failures do
    calls = []
    watch = Hecks::Adapters::PipelineBoard::FlagWatch.new(root: repo, runner: launcher(calls))

    expect(watch.synced?).to be(true)
    expect(calls).to eq([[[File.join(repo, "exe", "hecks"), "RedFlag.sync!", "checkout.value=#{repo}", "--wait"], repo]])
  end

  it "names a failed sync on stderr and answers false, so the next tick tries again", :aggregate_failures do
    watch = Hecks::Adapters::PipelineBoard::FlagWatch.new(root: repo, runner: ->(*, **) { ["boom\n", status_of(false)] })

    expect { expect(watch.synced?).to be(false) }.to output(/red flag sync failed: boom/).to_stderr
  end
end

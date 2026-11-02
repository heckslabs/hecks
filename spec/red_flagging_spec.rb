require "spec_helper"
require "tmpdir"
require "open3"
require "json"
require "hecks/hecks/adapters/red_flagging"
require "hecks/hecks/adapters/git_train"
require "hecks/pipeline_board/adapters/pipeline_stages/strip"

# The adapter behind the RedFlag port: raise, note, check in, lower, survey CI, and the refusals of
# the push train and the pipeline board's flag row. Every example builds its own repository.
RSpec.describe Hecks::Adapters::RedFlagging do
  let(:dir) { Dir.mktmpdir("hecks-red-flagging-spec") }
  let(:repo) { File.join(dir, "repo") }
  let(:runs) { [] }
  let(:flagging) { described_class.new(checkout: repo, runner: ->(argv, **) { gh(argv) }) }

  after { FileUtils.remove_entry(dir) }

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out
  end

  # A fake GitHub: the run list answers `runs`, a run view answers one failed job.
  def gh(argv)
    return [true, JSON.generate(runs)] if argv[1] == "run" && argv[2] == "list"

    jobs = [{ "name" => "rspec", "conclusion" => "failure" }, { "name" => "lint", "conclusion" => "success" }]
    [true, JSON.generate("jobs" => jobs)]
  end

  def repository
    FileUtils.mkdir_p(repo)
    git("init", "-b", "main")
    git("commit", "--allow-empty", "-m", "first")
  end

  def red_run = [{ "databaseId" => 7, "status" => "completed", "conclusion" => "failure", "headSha" => "abcdef1234567" }]

  def outcome(answer) = answer.dig(:outcome, :value)

  before { repository }

  it "raises a flag carrying the CI run and failed jobs", :aggregate_failures do
    answer = flagging.hoist(commit: "abcdef1234567", detail: "abcdef1234: CI run 7 failure; failed jobs: rspec, fuzz")

    expect(outcome(answer)).to eq("raised")
    expect(answer.values_at(:ci_run, :jobs).map { |v| v[:value] }).to eq(["7", "rspec, fuzz"])
  end

  it "notes a second red run on the flag, not a new flag", :aggregate_failures do
    flagging.hoist(commit: "aaaaaaaaaaaa")
    answer = flagging.hoist(commit: "bbbbbbbbbbbb")

    expect(outcome(answer)).to eq("noted")
    expect(answer.dig(:flag, :value)).to eq("flag-aaaaaaaaaa")
  end

  it "checks a session in and says what it takes", :aggregate_failures do
    flagging.hoist(commit: "aaaaaaaaaaaa")
    answer = flagging.sign_in(session: "s1", taking: "red-a")

    expect(outcome(answer)).to eq("checked_in")
    expect(answer.dig(:taking, :value)).to eq("red-a")
  end

  it "refuses a check-in when no flag stands" do
    expect { flagging.sign_in(session: "s1", taking: "red-a") }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no red flag/)
  end

  it "lowers the flag, and answers idle when none stands", :aggregate_failures do
    flagging.hoist(commit: "aaaaaaaaaaaa")

    expect(outcome(flagging.lower)).to eq("cleared")
    expect(outcome(flagging.lower)).to eq("idle")
  end

  it "raises the flag when the newest CI run of main is red", :aggregate_failures do
    runs.replace(red_run)
    answer = flagging.survey

    expect(outcome(answer)).to eq("raised")
    expect(answer.dig(:jobs, :value)).to eq("rspec")
  end

  it "lowers the flag when the newest CI run of main is green" do
    flagging.hoist(commit: "aaaaaaaaaaaa")
    runs.replace([{ "databaseId" => 8, "status" => "completed", "conclusion" => "success", "headSha" => "bbbbbbbbbbbb" }])

    expect(outcome(flagging.survey)).to eq("cleared")
  end

  it "leaves the flag as it is while the newest run is still going", :aggregate_failures do
    flagging.hoist(commit: "aaaaaaaaaaaa")
    runs.replace([{ "databaseId" => 9, "status" => "in_progress", "conclusion" => nil, "headSha" => "cccccccccccc" }])

    expect(outcome(flagging.survey)).to eq("idle")
    expect(flagging.status[:text]).to include("main is red")
  end

  it "says main is not flagged when no flag stands" do
    expect(flagging.status[:text]).to eq("main is not flagged\n")
  end

  it "refuses the push train while main is red, naming the flag", :aggregate_failures do
    git("remote", "add", "origin", repo)
    git("fetch", "origin")
    flagging.hoist(commit: "aaaaaaaaaaaa")

    expect { Hecks::Adapters::GitTrain.new.carry(checkout: repo) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /main is red: flag flag-aaaaaaaaaa/)
  end

  it "shows the flag, red time and helpers as the first row of the pipeline board" do
    flagging.hoist(commit: "aaaaaaaaaaaa")
    flagging.sign_in(session: "s1", taking: "red-a")
    flag = JSON.parse(File.read(File.join(repo, ".git", "hecks-red-flag.json")))
    rows = Hecks::Adapters::PipelineBoard::Strip.flag(flag, Time.now)

    expect(rows.first).to include(name: "Red flag", state: "failed", detail: a_string_including("helping: s1 takes red-a"))
  end

  it "shows no flag row while main is not flagged" do
    expect(Hecks::Adapters::PipelineBoard::Strip.flag(nil, Time.now)).to eq([])
  end
end

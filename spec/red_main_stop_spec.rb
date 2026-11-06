require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "support/registry_double"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/git_rehearsal"
require "hecks/hecks/adapters/dispatching"

# A red main is a full stop: the train refuses a boarding that fixes no open red row, the dispatch
# fill starts only red rows, and the due line leads with STOP. GitHub and the clock are stand-ins,
# the repository is a temp clone of a local bare remote, and no network is reached.
RSpec.describe Hecks::Adapters::RedMain, :io do
  include RegistryDouble

  Run = Hecks::Adapters::MainCiReader::Run

  let(:scratch) { Dir.mktmpdir("hecks-red-main") }
  let(:work) { File.join(scratch, "work") }
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end
  let(:red) { Run.new(id: "77", conclusion: "failure", created_at: "2026-11-01T10:00:00Z", sha: "abcdef0123456789", failed_job: "rspec") }
  let(:green) { Run.new(id: "78", conclusion: "success", created_at: "2026-11-01T11:00:00Z", sha: "bbbbbbbbbbbb", failed_job: nil) }
  let(:cancelled) { Run.new(id: "79", conclusion: "cancelled", created_at: "2026-11-01T12:00:00Z", sha: "cccccccccccc", failed_job: nil) }
  let(:ticking) { Run.new(id: "80", conclusion: nil, created_at: "2026-11-01T13:00:00Z", sha: "dddddddddddd", failed_job: nil) }
  let(:now) { [Time.utc(2026, 11, 1, 14)] }
  let(:clock) { instance_double(Time.singleton_class, now: nil).tap { |c| allow(c).to receive(:now) { now.first } } }
  let(:runs) { [red] }
  let(:reader) { instance_double(Hecks::Adapters::MainCiReader).tap { |r| allow(r).to receive(:runs!) { runs } } }
  let(:world) { instance_double(Hecks::Runtime::World, for_verb: { cache_minutes: 5 }) }
  let(:registry) { registry_double(world: world) }
  let(:mint) { instance_double(Hecks::Adapters::GitTrain::MintStep, run: "the Hecks shape did not move") }
  let(:open_rows) { [{ id: "red-no-era-held" }, { id: "red-main-77" }] }

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  def board(**held)
    described_class_train.carry(checkout: { value: work }, **held)
  end

  def described_class_train
    Hecks::Adapters::GitTrain.new(mint: mint, registry: registry, reader: reader, clock: clock)
  end

  def refusal_of(**held)
    board(**held)
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  def remote_head = git("rev-parse", "main", dir: File.join(scratch, "origin.git"))

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
    commit("second")
    allow(Hecks::Adapters::RedMainLine).to receive(:open_red_rows).and_return(open_rows)
  end

  after { FileUtils.remove_entry(scratch) }

  describe "the train while main is red" do
    it "refuses a plain boarding by name, listing the open red rows, before it mints or pushes" do
      expect(mint).not_to receive(:run)

      expect(refusal_of).to eq(
        "main is red (CI run 77 on abcdef012, rspec): only a push that fixes a red row goes out; " \
        "board again with fixes=<red row> (rows: red-no-era-held, red-main-77)"
      )
      expect(remote_head).not_to eq(git("rev-parse", "main"))
    end

    it "lets a boarding through that names an open red row, leading its report with STOP" do
      answer = board(fixes: { value: "red-no-era-held" })

      expect(answer.dig(:report, :value)).to start_with(
        "STOP: main is red since 2026-11-01T10:00:00Z (rspec): only fixes go out\n"
      )
      expect(remote_head).to eq(git("rev-parse", "main"))
    end

    it "refuses a row that is not open, whether unknown or done" do
      expect(refusal_of(fixes: { value: "red-gone" })).to start_with(
        "main is red (CI run 77 on abcdef012, rspec): fixes=red-gone names no open red-* Work row; only a push"
      )
    end

    it "lists at most five open red rows" do
      allow(Hecks::Adapters::RedMainLine).to receive(:open_red_rows).and_return((1..7).map { |n| { id: "red-r#{n}" } })

      expect(refusal_of).to end_with("(rows: red-r1, red-r2, red-r3, red-r4, red-r5)")
    end

    it "says none are open when there are no red rows" do
      allow(Hecks::Adapters::RedMainLine).to receive(:open_red_rows).and_return([])

      expect(refusal_of).to end_with("(rows: none open)")
    end
  end

  describe "what counts as red, clear or unknown" do
    def state = described_class.state(registry, checkout: work, reader: reader, clock: clock)

    it "is red on a failure, and a run still going after it does not clear it" do
      expect([runs.replace([ticking, red]), state.kind]).to eq([[ticking, red], :red])
    end

    it "is clear once a finished success follows the failure" do
      runs.replace([green, red])

      expect(state.kind).to eq(:clear)
    end

    it "ignores a cancelled run, in front of a failure or of a success" do
      runs.replace([cancelled, red])
      expect(state.kind).to eq(:red)

      File.delete(File.join(git("rev-parse", "--git-common-dir"), "hecks-red-main.json"))
      runs.replace([cancelled, green, red])
      expect(state.kind).to eq(:clear)
    end

    it "is unknown, and says so in one line, when gh fails" do
      allow(reader).to receive(:runs!).and_raise(Hecks::Adapters::MainCiReader::Unreadable)

      expect([state.kind, state.lead]).to eq([:unknown, "main CI state unknown: gh failed; stop not applied\n"])
    end

    it "fails open: a boarding goes through with the notice" do
      allow(reader).to receive(:runs!).and_raise(Hecks::Adapters::MainCiReader::Unreadable)

      expect(board.dig(:report, :value)).to start_with("main CI state unknown: gh failed; stop not applied\n")
      expect(remote_head).to eq(git("rev-parse", "main"))
    end

    it "is off where the world declares no stop" do
      no_world = registry_double(world: nil)

      expect(described_class.state(no_world, checkout: work, reader: reader, clock: clock).kind).to eq(:off)
    end

    it "keeps the gh answer for the world's minutes, and asks again after them" do
      2.times { state }
      expect(reader).to have_received(:runs!).once

      now[0] += 6 * 60
      state
      expect(reader).to have_received(:runs!).twice
    end

    it "asks gh only for finished runs" do
      gh = Hecks::Adapters::MainCiReader.new
      allow(Open3).to receive(:capture2).and_return(["[]", instance_double(Process::Status, success?: true)])

      gh.runs!

      expect(Open3).to have_received(:capture2).with("gh", "run", "list", "--workflow", "CI", "--branch", "main",
                                                     "--status", "completed", any_args)
    end
  end

  describe "the dispatch fill while main is red" do
    let(:row) { Hecks::Adapters::Dispatching::Plan::Row }
    let(:planned) { [row.new(key: "other", title: "t", detail: "d", area: []), row.new(key: "red-x", title: "t", detail: "d", area: [])] }

    def report(stop)
      rows = instance_double(Hecks::Adapters::Dispatching::Rows, planned: planned, started: [], runs: {})
      standins = { load: -> { 1.0 }, cpus: 4, rows: rows, red_main: stop }
      Hecks::Adapters::Dispatching.new(settings: standins).choose(repo: { value: scratch }).dig(:report, :value)
    end

    it "starts only red rows and names every other row as waiting" do
      text = report(described_class::State.new(kind: :red, run: red))

      expect(text).to include("would start red-x").and include("other waits: main is red, only red rows start")
      expect(text).not_to include("would start other")
    end

    it "is unchanged when the state is unknown, bar the one-line notice" do
      text = report(described_class::State.new(kind: :unknown))

      expect(text).to include("would start other", "would start red-x", "main CI state unknown: gh failed; stop not applied")
    end

    it "is unchanged when main is clear" do
      expect(report(described_class::State.new(kind: :clear))).to include("would start other")
    end
  end

  describe "the due line" do
    it "leads with STOP while main is red, one line" do
      allow(Hecks::Runtime::Asking).to receive(:registry).and_return(registry)
      allow(Hecks::Adapters::MainCiReader).to receive(:new).and_return(reader)
      git("branch", "--set-upstream-to=origin/main", "main")

      text = Hecks::Adapters::GitRehearsal.new.due(checkout: work)[:text]

      expect(text.lines.first).to eq("STOP: main is red since 2026-11-01T10:00:00Z (rspec): only fixes go out\n")
      expect(text.scan("STOP:").size).to eq(1)
    end
  end
end

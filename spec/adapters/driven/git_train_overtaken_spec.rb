require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# A boarding that landings overtake while its gate runs: the drift checks take minutes, and main
# takes new commits meanwhile. The boarding still opens its pull request for the tip it gated, the
# newer commits stay on local main for the next boarding, and a main that has lost the
# gated tip is refused. Against a local bare repository and a clone of it.
RSpec.describe "a train boarding overtaken by landings during its gate", :io do
  let(:scratch) { Dir.mktmpdir("hecks-git-train-overtaken") }
  let(:work) { File.join(scratch, "work") }
  let(:settlement_class) { Hecks::Adapters::GitTrain::Settlement }

  # A drift check that passes and lands a commit on main, as a coder's landing does meanwhile.
  LANDING = ["git", "commit", "-q", "--allow-empty", "-m", "landed meanwhile"].freeze

  OVERTAKEN_IDENTITY = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
                         "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }.freeze

  def git(*args, dir: work)
    out, err, status = Open3.capture3(OVERTAKEN_IDENTITY, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
    git("rev-parse", "HEAD")
  end

  def github(argv, **)
    return [true, "https://github.test/heckslabs/hecks/pull/1\n"] if argv[1..2] == %w[pr create]
    return [false, "no pull request found"] if argv[1..2] == %w[pr view]

    [true, ""]
  end

  def still_mint = instance_double(Hecks::Adapters::GitTrain::MintStep, run: "the Hecks shape did not move")

  # Boards the head of main through a gate whose drift checks are the given commands.
  def board(*checks)
    stub_const("Hecks::Adapters::GitTrain::Settlement::DRIFT", checks.freeze)
    Hecks::Adapters::GitTrain.new(mint: still_mint, runner: method(:github)).carry(checkout: { value: work })
  end

  def remote(ref) = git("ls-remote", "origin", ref).split.first

  def branch_for(sha) = Hecks::Adapters::GitTrain::PullRequestBoarding.branch_for(sha)

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    git("config", "user.name", "A")
    git("config", "user.email", "a@example.test")
    commit("first")
    git("push", "-q", "origin", "main")
    FileUtils.mkdir_p(File.join(work, "exe"))
    File.write(File.join(work, "exe", "hecks"), "")
    @gated = commit("second")
  end

  after { FileUtils.remove_entry(scratch) }

  it "opens the pull request for the tip it gated when main moved during the gate", :aggregate_failures do
    answer = board(LANDING)

    expect(answer).to include(outcome: { value: "queued" }, boarded: { value: @gated })
    expect(remote("refs/heads/#{branch_for(@gated)}")).to eq(@gated)
  end

  it "leaves the commit that landed meanwhile on local main, and names it", :aggregate_failures do
    report = board(LANDING)[:report][:value]

    expect(report).to include("1 commit(s) landed meanwhile and were not pushed")
    expect(git("log", "--format=%s", "#{@gated}..main")).to eq("landed meanwhile")
  end

  it "does not fault when two landings arrive during one gate" do
    expect(board(LANDING, LANDING)).to include(outcome: { value: "queued" }, boarded: { value: @gated })
  end

  it "still refuses a main that no longer holds the gated tip, and pushes nothing", :aggregate_failures do
    rewrite = ["git", "reset", "-q", "--hard", "HEAD~1"]

    expect { board(rewrite) }.to raise_error(failure, /main moved since boarding.*board again/)
    expect(remote("refs/heads/#{branch_for(@gated)}")).to be_nil
  end

  describe "a drift check that read the checkout while a landing moved it" do
    # Lands a commit and finds drift the first time it runs, and is clean from then on.
    def torn_check(verdict)
      marker = File.join(scratch, "ran")
      ["sh", "-c", "test -e #{marker} && exit 0; touch #{marker}; #{LANDING.join(" ").sub("landed meanwhile", "late")}; " \
                   "echo generated tree differs; exit #{verdict}"]
    end

    it "is run again, and the boarding goes on when it is then clean" do
      expect(board(torn_check(1))).to include(outcome: { value: "queued" }, boarded: { value: @gated })
    end

    it "refuses at once when main did not move, naming the check" do
      still = ["sh", "-c", "echo generated tree differs; exit 1"]

      expect { board(still) }.to raise_error(failure, /generated tree differs/)
    end
  end

  describe "a landing that arrives while the shape ledger is settled" do
    let(:ledger) { File.join(work, settlement_class::LEDGER) }

    # A settlement that writes the ledger while a coder's landing reaches main.
    def settle_while_landing
      script = File.join(scratch, "settle.sh")
      File.write(script, "#!/bin/sh\n#{LANDING.join(" ").sub("landed meanwhile", "late")}\nprintf changed > #{ledger}\n")
      FileUtils.chmod("+x", script)
      stub_const("Hecks::Adapters::GitTrain::Settlement::SETTLE", [script].freeze)
    end

    before do
      FileUtils.mkdir_p(File.dirname(ledger))
      File.write(ledger, "old")
      git("add", settlement_class::LEDGER)
      git("commit", "-q", "-m", "ledger")
      settle_while_landing
    end

    it "refuses the boarding, so the landing never goes out under the settlement's commit", :aggregate_failures do
      expect { board }.to raise_error(failure, /main moved since boarding/)
      expect(git("log", "-1", "--format=%s", "main")).to eq("late")
    end

    it "drops what the settlement wrote, so the next boarding finds the ledger untouched", :aggregate_failures do
      expect { board }.to raise_error(failure)
      expect(git("status", "--porcelain", "--untracked-files=no")).to eq("")
    end
  end
end

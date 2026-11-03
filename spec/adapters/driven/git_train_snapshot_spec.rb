require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"
require_relative "../../support/thread_parking"

# A pinned boarding, against a bare origin and a clone of it in a temporary directory. The handoff
# boards while origin still stands at the green head and local main is that head plus the handoff;
# every other state refuses by name and pushes nothing. The mint is a stub.
RSpec.describe Hecks::Adapters::GitTrain, :io do
  let(:scratch) { Dir.mktmpdir("hecks-git-train-snapshot") }
  let(:work) { File.join(scratch, "work") }
  let(:origin) { File.join(scratch, "origin.git") }
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name, dir: work, text: name)
    File.write(File.join(dir, name), text)
    git("add", name, dir: dir)
    git("commit", "-q", "-m", name, dir: dir)
  end

  def short(sha) = sha[0, 9]

  def origin_head = git("rev-parse", "main", dir: origin)

  # Another machine lands on origin's main, and the new head is returned.
  def push_elsewhere(name)
    other = File.join(scratch, "other")
    git("clone", "-q", "-b", "main", origin, other, dir: scratch) unless File.directory?(other)
    commit(name, dir: other)
    git("push", "-q", "origin", "main", dir: other)
    git("rev-parse", "HEAD", dir: other)
  end

  # The coordinator's check: the green head of origin, and one handoff committed on top of it.
  def handoff_on_green
    green = origin_head
    commit("handoff")
    [green, git("rev-parse", "main")]
  end

  def still_mint = instance_double(described_class::MintStep, run: "the Hecks shape did not move")

  def board(**handoff)
    described_class.new(mint: still_mint).carry(checkout: { value: work }, **handoff)
  end

  def pinned_board(pinned, green) = board(pinned: { value: pinned }, green: { value: green })

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    git("config", "user.name", "A")
    git("config", "user.email", "a@example.test")
    commit("first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.rm_rf(scratch) }

  it "boards a pinned handoff when origin stands at green and main is green plus the handoff", :aggregate_failures do
    green, pinned = handoff_on_green
    expect(pinned_board(pinned, green)).to include(outcome: { value: "pushed" }, pushed: { value: pinned })
    expect(origin_head).to eq(pinned)
  end

  it "refuses when origin's main moved since the check, naming both heads, and pushes nothing", :aggregate_failures do
    green, pinned = handoff_on_green
    moved = push_elsewhere("elsewhere")
    expect { pinned_board(pinned, green) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /main moved since the check: #{short(green)} -> #{short(moved)}/)
    expect(origin_head).to eq(moved)
  end

  it "refuses when local main holds a commit besides the handoff, and pushes nothing", :aggregate_failures do
    green, pinned = handoff_on_green
    commit("extra")
    expect { pinned_board(pinned, green) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /local main holds 1 commits besides the handoff/)
    expect(origin_head).to eq(green)
  end

  it "refuses when the checkout has an uncommitted edit beyond the handoff, and pushes nothing", :aggregate_failures do
    green, pinned = handoff_on_green
    File.write(File.join(work, "first"), "edited")
    expect { pinned_board(pinned, green) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /tree differs from green beyond the handoff: first/)
    expect(origin_head).to eq(green)
  end

  it "refuses a pinned handoff that names no green head, and pushes nothing", :aggregate_failures do
    _green, pinned = handoff_on_green
    expect { board(pinned: { value: pinned }) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /needs the green head it was checked against/)
    expect(origin_head).not_to eq(pinned)
  end

  # Two boards of one checkout: the first is held inside its mint until the second is parked on the
  # line. Returns the mints started while the second waited, then the mints started in all.
  # A mint that records each board that started, then holds the line until released.
  def holding_mint(started, release)
    instance_double(described_class::MintStep).tap do |mint|
      allow(mint).to receive(:run) do
        started << true
        release.pop
        "minted"
      end
    end
  end

  def board_thread(mint) = Thread.new { described_class.new(mint: mint).carry(checkout: { value: work }) }

  def release_and_join(release, *boards)
    2.times { release << true }
    boards.each(&:join)
  end

  # Whether a second mint started within a bounded wait while the first still holds the line.
  def entered_while_held(started)
    ThreadParking.wait_for(timeout: 1) { started.size > 1 }
    true
  rescue ThreadParking::NeverReached
    false
  end

  # Returns whether the second board entered its mint while the first held the line, then how many
  # mints ran in all.
  def boards_in_turn
    started = Queue.new
    release = Queue.new
    mint = holding_mint(started, release)
    first = board_thread(mint)
    ThreadParking.wait_for { started.size == 1 }
    second = board_thread(mint)
    overlapped = entered_while_held(started)
    release_and_join(release, first, second)
    [overlapped, started.size]
  end

  it "runs two boards of one checkout one at a time: the second waits for the first", :aggregate_failures do
    expect(boards_in_turn).to eq([false, 2])
    expect(origin_head).to eq(git("rev-parse", "main"))
  end
end

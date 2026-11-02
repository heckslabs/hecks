require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# The push hold: the train keeps the landing line's front place and the QA quiet marker from the
# settlement to the push result. Temp directories stand in for the repository's git directory; the
# clock is injected and no session is real.
RSpec.describe Hecks::Adapters::GitTrain::Hold, :aggregate_failures do
  let(:dir) { Dir.mktmpdir("hecks-push-hold") }
  let(:said) { Queue.new }
  let(:offset) { [0] }
  let(:clock) { -> { Time.now + offset.first } }
  let(:marker) { Hecks::Adapters::QaQuiesceMarker.new(path: File.join(dir, "quiesce"), clock: clock) }

  after { FileUtils.remove_entry(dir) }

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def hold = described_class.new(dir, dir, branch: "main", marker: marker, **tune)

  def tune = { locks: [], say: ->(text) { said << text }, heartbeat: 0.05, clock: clock }

  def lineup(**more) = Hecks::Adapters::GitLanding::Lineup.new(dir, **tune, **more)

  def answer = { report: { value: "pushed" } }

  def queue = Dir.glob(File.join(dir, "hecks-landing", "queue", "*.ticket"))

  def holding(&block)
    entered = Queue.new
    release = Queue.new
    thread = Thread.new do
      hold.around { ((entered << true) && release.pop && block&.call) || answer }
    end
    entered.pop
    [thread, release]
  end

  def start_landing = Thread.new { lineup.stand("work/a", onto: "main", checkout: dir) { |_| :landed } }

  def heard_second = Timeout.timeout(5) { loop { break if said.pop.include?("2nd in line") } }

  def queued_behind_the_front
    line = Hecks::Adapters::GitLanding::Line.new(dir, clock: clock, heartbeat: 0.05)
    front = line.join("work/front", ready: true).tap { |ticket| line.promote(ticket) }
    waiting = line.join("work/b", ready: true)
    [line, front, waiting]
  end

  def hold_behind(line, front)
    Thread.new { hold.around { answer } }.tap do
      heard_second
      line.leave(front)
    end
  end

  HELD = /\Alanding is held by the push train \(main, since \d\d:\d\d:\d\dZ\); try again after the push\z/

  def refused_landing = -> { lineup(wait_minutes: 0.02).stand("work/a", onto: "main", checkout: dir) { |_| raise "landed" } }

  def land_after_release
    thread, release = holding
    landing = start_landing
    heard_second
    release << true
    thread.join
    landing.value
  end

  it "makes a landing wait, then refuses it by name while the hold stands" do
    thread, release = holding
    expect(&refused_landing).to raise_error(failure, HELD)
    release << true
    thread.join
  end

  it "lets the landing through once the hold is released" do
    expect(land_after_release).to eq(:landed)
  end

  it "tells the story: whom it waited behind and how many queued branches it holds off" do
    line, front, waiting = queued_behind_the_front
    outcome = hold_behind(line, front).value
    line.leave(waiting)

    expect(outcome.dig(:report, :value)).to include("2nd in line", "holding landing for 1 queued branch")
  end

  describe "release" do
    it "frees the line and the marker after a success" do
      hold.around { answer }

      expect(queue).to be_empty
      expect(marker.read).to be_nil
    end

    it "frees them after a refusal, and names the release in the refusal" do
      attempt = -> { hold.around { raise failure, "the push of main was refused" } }

      expect(&attempt).to raise_error(failure, /refused; the push hold on landing was released by the failure/)
      expect(queue).to be_empty
      expect(marker.read).to be_nil
    end

    it "frees them after any other failure" do
      expect { hold.around { raise "disk full" } }.to raise_error(RuntimeError, "disk full")
      expect(queue).to be_empty
      expect(marker.read).to be_nil
    end
  end

  describe "a stale hold" do
    def ghost_hold
      line = Hecks::Adapters::GitLanding::Line.new(dir, clock: clock, heartbeat: 3600)
      line.join("main", jump: true, hold: true, ready: false).tap { |ghost| line.promote(ghost) }
    end

    it "is superseded by the next landing once its heartbeat is older than the stale window" do
      ghost = ghost_hold
      offset[0] = 31 * 60
      landed = lineup(stale_minutes: 30).stand("work/a", onto: "main", checkout: dir) { |note| note }

      expect(landed).to include("superseded the abandoned landing of the push train (main, since")
      ghost.close
    end
  end

  describe "the QA quiet marker" do
    it "is set for the span of the hold with its reason, and cleared after", :aggregate_failures do
      seen = nil
      hold.around { (seen = marker.active) && answer }

      expect(seen.reason).to eq("push train holding main")
      expect(seen.owner).to start_with("push-train-")
      expect(marker.read).to be_nil
    end

    it "leaves another owner's marker alone, before and after" do
      marker.hold!(owner: "mint-agent", reason: "rehearsal to mint")
      hold.around { answer }

      expect(marker.read.owner).to eq("mint-agent")
    end

    it "does not clear a marker another job set during the hold" do
      hold.around do
        marker.hold!(owner: "other-job", reason: "mint", force: true)
        answer
      end

      expect(marker.read.owner).to eq("other-job")
    end
  end
end

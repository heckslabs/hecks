require "spec_helper"
require_relative "support/pipeline_board_world"
require_relative "support/thread_parking"
require "timeout"

# The one lock every boot in the board process goes through: a boot thread waits its turn, a
# request thread waits only so long and then says a boot is still going.
RSpec.describe Hecks::Adapters::PipelineBoard::BootLock do
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }

  # Holds the lock on another thread until released; answers the release and the thread.
  def held_elsewhere
    entered = Queue.new
    release = Queue.new
    thread = Thread.new do
      described_class.exclusive do
        entered << :in
        release.pop
      end
    end
    entered.pop
    [release, thread]
  end

  # Lets the thread holding the lock go, and waits for it.
  def let_go(release, thread)
    release << :go
    thread.join
  end

  # Lets go of the lock after a short while, on a thread that does not sleep but waits on a queue.
  def release_soon(release)
    Thread.new do
      Queue.new.pop(timeout: 0.1)
      release << :go
    end
  end

  it "runs the block and answers its result" do
    expect(described_class.exclusive { :done }).to eq(:done)
  end

  it "lets a request thread through at once when no boot holds the lock" do
    expect(described_class.exclusive(wait: 1) { :done }).to eq(:done)
  end

  it "gives up on a boot that holds the lock past the wait, saying a boot is still going", :aggregate_failures do
    release, thread = held_elsewhere
    expect { described_class.exclusive(wait: 0.2) { :never } }.to raise_error(unavailable, /still going/)
    release << :go
    thread.join
  end

  it "takes the lock once the boot lets go within the wait" do
    release, thread = held_elsewhere
    release_soon(release)
    expect(described_class.exclusive(wait: 5) { :done }).to eq(:done)
    thread.join
  end

  it "makes a boot thread wait its turn, with no limit" do
    release, thread = held_elsewhere
    waiter = ThreadParking.wait_until_parked(Thread.new { described_class.exclusive { :after } })
    release << :go
    expect([Timeout.timeout(5) { waiter.value }, thread.join(5)&.class]).to eq([:after, Thread])
  end

  it "lets go of the lock when the block raises, so the next request gets in", :aggregate_failures do
    expect { described_class.exclusive(wait: 1) { raise "boot broke" } }.to raise_error("boot broke")
    expect(described_class.exclusive(wait: 0.2) { :free }).to eq(:free)
  end

  it "waits by the clock it is given" do
    release, thread = held_elsewhere
    ticks = [0.0, 0.0, 31.0]
    expect { described_class.exclusive(wait: 30, clock: -> { ticks.shift || 99.0 }) { :never } }.to raise_error(unavailable)
    let_go(release, thread)
  end
end

require_relative "support/thread_parking"

RSpec.describe ThreadParking do
  let(:release) { Queue.new }

  after { release << true }

  it "answers the thread once it is blocked on a queue" do
    blocked = Thread.new { release.pop }

    expect(described_class.wait_until_parked(blocked)).to equal(blocked)
  end

  it "leaves the blocked thread alive" do
    blocked = Thread.new { release.pop }
    described_class.wait_until_parked(blocked)

    expect(blocked).to be_alive
  end

  it "returns for a thread that has already finished" do
    done = Thread.new { :done }
    done.join

    expect(described_class.wait_until_parked(done)).to equal(done)
  end

  it "raises when a thread never parks within the timeout" do
    spinning = Thread.new { loop { Thread.pass } }

    expect { described_class.wait_until_parked(spinning, timeout: 0.05) }
      .to raise_error(ThreadParking::NeverReached)
    spinning.kill
  end

  it "waits for a condition another thread makes true" do
    flag = []
    Thread.new { flag << :set }

    expect { described_class.wait_for { !flag.empty? } }.not_to raise_error
  end

  it "lets the given time pass" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    described_class.elapse(0.05)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.04
  end
end

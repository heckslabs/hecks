require "spec_helper"

RSpec.describe ProcessTree do
  # Starts a process that leads a group of its own and forks a sleeping child of its own.
  def start_family
    pid = Process.spawn("sh", "-c", "sleep 60 & wait", pgroup: true, in: File::NULL, out: File::NULL)
    ThreadParking.wait_for { described_class.descendants(pid).any? }
    pid
  end

  after { described_class.end_tree(@pid) if @pid && described_class.alive?(@pid) }

  it "finds the processes under a process, not the process itself", :aggregate_failures do
    @pid = start_family
    found = described_class.descendants(@pid).map(&:pid)
    expect(found).not_to include(@pid)
    expect(found.size).to eq(1)
  end

  it "ends a process and what it forked, and waits for them to be gone", :aggregate_failures do
    @pid = start_family
    kids = described_class.descendants(@pid).map(&:pid)
    described_class.end_tree(@pid)
    Process.wait(@pid)
    expect(kids.none? { |pid| described_class.alive?(pid) }).to be(true)
  end

  it "names the command a process runs" do
    expect(described_class.command(Process.pid)).to include("ruby")
  end

  it "does not count a process that is gone as alive" do
    pid = Process.spawn("true")
    Process.wait(pid)
    expect(described_class.alive?(pid)).to be(false)
  end
end

require "spec_helper"

RSpec.describe ChildProcessGuard do
  it "names a watched process that is left standing, and ends it", :aggregate_failures do
    pid = Process.spawn("sleep", "60")
    described_class.watch(pid)
    expect { described_class.check }.to raise_error(described_class::Left, /#{pid} \(sleep 60\)/)
    Process.wait(pid)
    expect(ProcessTree.alive?(pid)).to be(false)
  end

  it "says nothing when every watched process has ended" do
    pid = Process.spawn("true")
    described_class.watch(pid)
    Process.wait(pid)
    expect { described_class.check }.not_to raise_error
  end
end

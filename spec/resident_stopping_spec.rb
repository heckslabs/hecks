require "spec_helper"
require "hecks/adapters/driving/resident/server"

# What a resident does to the child of a line whose caller has gone (ADR 0201): the child leads a
# process group, and the whole group is stopped, `INT` first and then `TERM` and `KILL` for a child
# that does not leave. Nothing is signalled for real: the signals and the waits are stood in for.
RSpec.describe Hecks::Adapters::Driving::Resident::Stopping do
  let(:server) { Hecks::Adapters::Driving::Resident::Server.new("/checkout", "/checkout/exe/hecks") }
  let(:signals) { [] }
  let(:sleeps) { [] }

  before do
    allow(Process).to receive(:kill) { |signal, pid| signals << [signal, pid] }
    allow(server).to receive(:sleep) { |seconds| sleeps << seconds }
  end

  # The caller's end of the socket, closed: reading it ends at once.
  def caller_gone
    reader, writer = IO.pipe
    writer.close
    reader
  end

  it "signals the child's whole group, INT then TERM then KILL, after the waits", :aggregate_failures do
    server.send(:stop_when_gone, caller_gone, 4242)
    expect(signals).to eq([["INT", -4242], ["TERM", -4242], ["KILL", -4242]])
    expect(sleeps).to eq([0, 5, 10])
  end

  it "signals the child alone when its group is not made yet" do
    allow(Process).to receive(:kill) { |signal, pid| pid.negative? ? raise(Errno::ESRCH) : signals << [signal, pid] }
    server.send(:stop_when_gone, caller_gone, 4242)
    expect(signals.first).to eq(["INT", 4242])
  end

  it "stops signalling once the child is gone" do
    allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
    expect { server.send(:stop_when_gone, caller_gone, 4242) }.not_to raise_error
  end

  it "puts a process in a group, and ignores a refusal" do
    allow(Process).to receive(:setpgid).and_raise(Errno::EACCES)
    expect { server.send(:into_group, 4242, 4242) }.not_to raise_error
  end
end

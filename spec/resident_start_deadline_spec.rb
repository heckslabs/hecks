require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/client"

# A child forked from the resident says it has begun before it runs the line; one that never does
# is ended and its caller boots cold. The fork is real: it inherits a held lock file and another
# thread's mutex, as a resident's child does, and still begins or is ended.
RSpec.describe Hecks::Adapters::Driving::Resident::StartDeadline do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:server) { resident::Server.new("/checkout", "/checkout/exe/hecks") }
  let(:pipe) { IO.pipe }

  # Forks from a thread that is not the one holding a mutex, with a lock file held.
  def fork_holding(&)
    Dir.mktmpdir do |dir|
      lock = File.open(File.join(dir, "held.lock"), File::CREAT | File::RDWR)
      lock.flock(File::LOCK_EX)
      mutex = Mutex.new
      holder = Thread.new { mutex.synchronize { sleep } }
      sleep 0.05
      pid = fork(&)
      holder.kill
      return pid
    end
  end

  it "counts a child that wrote its note as begun, and consumes the note", :aggregate_failures do
    reader, writer = pipe
    writer.write("S\nD\tx\n")
    expect(server.send(:await_start, 1, reader, 1)).to be(true)
    expect(reader.read_nonblock(100)).to eq("D\tx\n")
  end

  it "counts a child that died before it began as unstarted, with no wait", :aggregate_failures do
    reader, writer = pipe
    writer.close
    expect(server.send(:await_start, 1, reader, 5)).to be(false)
  end

  it "ends a child that stays silent past the deadline", :aggregate_failures do
    pid = fork_holding { sleep }
    reader, = pipe
    allow(server).to receive(:signal_group) { |signal, target| Process.kill(signal, target) }
    expect(server.send(:await_start, pid, reader, 0.2)).to be(false)
    expect(Process.wait2(pid).last.termsig).to eq(9)
  end

  it "counts a note written as the deadline passed, once the child is reaped", :aggregate_failures do
    reader, writer = pipe
    expect(server.send(:started_late?, reader)).to be(false).or be_nil
    writer.write("S\n")
    expect(server.send(:started_late?, reader)).to be(true)
  end

  it "tells the caller its child never began" do
    client = StringIO.new
    server.send(:finish_line, client, instance_double(Process::Status, exitstatus: 0), false)
    expect(client.string).to eq("unstarted\n")
  end

  it "has the launcher boot cold on `unstarted`, never counting it as an exit status", :aggregate_failures do
    socket = instance_double(UNIXSocket)
    allow(resident::Waiting).to receive(:status).and_return("unstarted")
    allow(resident::Peer).to receive(:pid)
    expect(resident::Client.finish(socket)).to eq("unstarted")
    expect(resident::Client.instance_variable_get(:@gone)).to be_nil
  end
end

require "spec_helper"
require "socket"
require "timeout"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/client"

# A launcher waits for the status of its line without a time limit only while the resident's
# process stands; a resident that is gone, or whose socket closed, ends the wait with a said
# status of 1. A resident does not idle-exit while it holds a caller or runs a line. The two
# ends are a socket pair in this process.
RSpec.describe "a launcher whose resident is gone" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:ends) { UNIXSocket.pair }
  let(:gone_pid) { Process.spawn("true").tap { |pid| Process.wait(pid) } }
  let(:said) { "hecks: the resident went away while this line ran; its status is unknown\n" }

  def client = resident::Client

  def finish_quietly
    $stderr = StringIO.new
    Timeout.timeout(6) { client.finish(ends.first) }
  ensure
    $stderr = STDERR
  end

  describe "waiting for the status" do
    it "reads the status the resident sends" do
      resident::Wire.reply(ends.last, "status:3")
      expect(client.finish(ends.first)).to eq(3)
    end

    it "ends with 1 when the resident closes its end" do
      ends.last.close
      expect(finish_quietly).to eq(1)
    end

    it "says so when the resident closes its end" do
      ends.last.close
      expect { client.finish(ends.first) }.to output(said).to_stderr
    end

    it "ends with 1 when the resident's process is gone though its socket stays open" do
      allow(resident::Peer).to receive(:pid).and_return(gone_pid)
      expect(finish_quietly).to eq(1)
    end

    it "ends with 1 when the status line is half written and never finished" do
      ends.last.write("status:")
      expect(finish_quietly).to eq(1)
    end
  end

  describe "a resident that stands and is silent" do
    it "keeps waiting, since a line may be silent as long as it likes" do
      thread = Thread.new { resident::Waiting.status(ends.first, Process.pid) }
      expect(thread.join(2.5)).to be_nil
      ends.last.close
      thread.join(2)
    end
  end

  describe "whether a process stands" do
    it "says a process of another user stands" do
      allow(Process).to receive(:kill).and_raise(Errno::EPERM)
      expect(resident::Waiting.alive?(1)).to be(true)
    end

    it "says a process whose id is not known stands" do
      expect(resident::Waiting.alive?(nil)).to be(true)
    end
  end

  describe "the resident's idle exit" do
    let(:server) { resident::Server.new("/checkout", "/checkout/exe/hecks") }

    before do
      server.instance_variable_set(:@settings, { idle_seconds: 0.0 })
      server.instance_variable_set(:@active, Time.now - 60)
    end

    it "exits when nothing is held and no line runs" do
      expect(server.send(:idle?)).to be(true)
    end

    it "does not exit while a caller is held" do
      server.send(:hold, ends.last)
      expect(server.send(:idle?)).to be(false)
    end

    it "does not exit while a line runs" do
      gate = Queue.new
      line = Thread.new { gate.pop }
      server.instance_variable_get(:@monitors) << line
      expect(server.send(:idle?)).to be(false)
      gate << :done
    end
  end
end

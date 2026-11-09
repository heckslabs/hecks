require "spec_helper"
require "socket"
require "stringio"
require "tmpdir"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/client"

# The resident's three-word handshake and the limits on what it reads (ADR 0201): a line is run
# only when its caller answers `go`, so a caller that gave up never has its line run, and a caller
# that sends too much, too slowly, or from the wrong user is dropped. No process starts: the two
# ends are a socket pair in this process.
RSpec.describe "the resident's handshake" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:wire) { resident::Wire }
  let(:server) { resident::Server.new("/checkout", "/checkout/exe/hecks") }
  let(:ends) { UNIXSocket.pair }
  let(:request) { { argv: ["RedFlag.status"], env: { "HOME" => "/h" }, cwd: "/tmp", script: "/checkout/exe/hecks" } }

  def ready_server
    fingerprint = instance_double(resident::Fingerprint, changed?: false)
    server.instance_variable_set(:@fingerprint, fingerprint)
    server.instance_variable_set(:@environment, { "HOME" => "/h" })
    allow(server).to receive(:launch)
  end

  # Sends the request, then the three streams once the resident has said `fds`, as a launcher
  # does; answers the resident's first word.
  def send_line(caller_end)
    wire.write_request(caller_end, request)
    first = wire.read_line(caller_end, 5)
    3.times { caller_end.send_io(File.open(File::NULL)) } if first == "fds"
    first
  end

  # Runs the resident's side of one line on a thread and answers what the caller says next.
  def serve_line
    ready_server
    resident_end = ends.last
    thread = Thread.new { server.send(:handle, resident_end) }
    first = send_line(ends.first)
    yield ends.first, first
    thread.join(5)
  end

  describe "the words" do
    it "says ready and runs the line only after the caller answers go", :aggregate_failures do
      serve_line do |caller_end|
        expect(wire.read_reply(caller_end)).to eq("ready")
        wire.reply(caller_end, "go")
      end
      expect(server).to have_received(:launch).once
    end

    it "does not run a line whose caller closed the socket instead of answering" do
      serve_line do |caller_end|
        wire.read_reply(caller_end)
        caller_end.close
      end
      expect(server).not_to have_received(:launch)
    end

    it "does not run a line whose caller answers something other than go" do
      serve_line do |caller_end|
        wire.read_reply(caller_end)
        wire.reply(caller_end, "run")
      end
      expect(server).not_to have_received(:launch)
    end

    it "does not run a line when its caller had gone before the resident looked" do
      ready_server
      wire.write_request(ends.first, request)
      ends.first.close
      server.send(:handle, ends.last)
      expect(server).not_to have_received(:launch)
    end
  end

  describe "a line the resident will not serve" do
    let(:request) { super().merge(env: { "HOME" => "/other" }) }

    it "is answered stale with the reason, here the environment, and is not run", :aggregate_failures do
      serve_line { |_caller_end, first| expect(first).to eq("stale:env") }
      expect(server).not_to have_received(:launch)
    end
  end

  describe "the limits on a request" do
    def read(text, seconds: nil) = wire.read_request(StringIO.new(text), seconds: seconds)

    # A request body with the length it states, as `write_request` frames it.
    def framed(body) = "#{body.bytesize}\0#{body}"

    it "refuses a field longer than the limit" do
      expect { read(framed("1\0#{"a" * (wire::MAX_FIELD + 10)}")) }.to raise_error(wire::Refused)
    end

    it "refuses more fields than the limit" do
      expect { read(framed("#{wire::MAX_FIELDS + 1}\0")) }.to raise_error(wire::Refused)
    end

    it "refuses a count that is not a number" do
      expect { read(framed("many\0")) }.to raise_error(wire::Refused)
    end

    it "refuses a stated length that is not a number or is past the limit", :aggregate_failures do
      expect { read("many\0") }.to raise_error(wire::Refused)
      expect { read("#{wire::MAX_REQUEST + 1}\0") }.to raise_error(wire::Refused)
      expect { read("1" * 40) }.to raise_error(wire::Refused)
    end

    it "gives up on a request that stalls part way", :aggregate_failures do
      caller_end, resident_end = ends
      caller_end.write("40\0only")
      expect { wire.read_request(resident_end, seconds: 0.2) }.to raise_error(wire::Slow)
    end

    it "takes the request to the length it states and no further, so a stream behind it stays" do
      caller_end, resident_end = ends
      wire.write_request(caller_end, request)
      caller_end.send_io(File.open(File::NULL))
      wire.read_request(resident_end, seconds: 1)
      expect(resident_end.recv_io).to be_a(IO)
    end
  end

  describe "a caller that stalls" do
    # Takes a caller that sends its request, then `streams` of its three streams, then stalls; the
    # seconds it held the resident for.
    def held_for(streams = 0)
      stub_const("Hecks::Adapters::Driving::Resident::Serving::HANDLE_WAIT", 0.4)
      ready_server
      sent_by_caller(streams)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      server.send(:handle, ends.last)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    def sent_by_caller(streams)
      wire.write_request(ends.first, request)
      streams.times { ends.first.send_io(File.open(File::NULL)) }
    end

    it "is dropped within the one deadline of the whole exchange, and its line is not run", :aggregate_failures do
      expect(held_for).to be < 2
      expect(server).not_to have_received(:launch)
    end

    it "has the streams it had sent closed" do
      held_for(1)
      expect(ends.last).to be_closed
    end
  end

  describe "a resident that does not read" do
    it "does not hold the caller for ever: the write gives up" do
      caller_end, = ends
      huge = request.merge(env: { "BIG" => "x" * (8 << 20) })
      expect { wire.write_request(caller_end, huge, seconds: 0.3) }.to raise_error(wire::Slow)
    end
  end

  describe "who is calling" do
    it "knows the user of the process on the other end of a socket", :aggregate_failures do
      expect(resident::Peer.uid(ends.first)).to eq(Process.uid)
      expect(resident::Peer.trusted?(ends.first)).to be(true)
    end

    it "drops a caller of another user without reading its request" do
      allow(resident::Peer).to receive(:trusted?).and_return(false)
      server.send(:handle, ends.last)
      expect(ends.last).to be_closed
    end
  end

  describe "the client giving up on a slow resident" do
    def script = File.expand_path("../exe/hecks", __dir__)

    around do |example|
      Dir.mktmpdir("hrh") do |dir|
        saved = ENV.fetch("HECKS_CACHE_DIR", nil)
        ENV["HECKS_CACHE_DIR"] = dir
        FileUtils.mkdir_p(resident::Paths.directory, mode: 0o700)
        example.run
      ensure
        ENV["HECKS_CACHE_DIR"] = saved
      end
    end

    # Whether the other end closed the socket, reading what it had sent first.
    def closed_by_caller?(accepted)
      loop do
        return false unless accepted.wait_readable(2)

        accepted.read_nonblock(65_536, exception: false).nil? and return true
      end
    end

    # A resident that has the socket bound and accepts only after the caller has given up.
    def late_accept(root)
      listener = UNIXServer.new(resident::Paths.socket(root))
      File.chmod(0o600, resident::Paths.socket(root))
      answer = resident::Client.ask(root, script)
      [answer, listener.accept]
    ensure
      listener&.close
    end

    it "closes its end of the socket before it boots on its own, so a late resident finds it gone", :aggregate_failures do
      stub_const("Hecks::Adapters::Driving::Resident::Client::HANDSHAKE", 0.3)
      answer, accepted = late_accept("/c")
      expect(answer).to eq([nil, "busy"])
      expect(closed_by_caller?(accepted)).to be(true)
    end
  end
end

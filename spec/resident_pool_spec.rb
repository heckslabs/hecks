require "spec_helper"
require "socket"
require "tmpdir"
require "timeout"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/client"

# A resident that takes callers concurrently (ADR 0201): a slow caller holds up no other, a
# launcher waits only briefly for a busy resident, one launcher starts the replacement when the
# code changes, and a child holds no other caller's socket. No process starts: the callers are
# sockets and the threads are this process's.
RSpec.describe "the resident's concurrency" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:server) { resident::Server.new("/checkout", "/checkout/exe/hecks") }

  def client = resident::Client

  def claim = resident::Claim

  def script = File.expand_path("../exe/hecks", __dir__)

  around do |example|
    Dir.mktmpdir("hrp") do |dir|
      saved = ENV.fetch("HECKS_CACHE_DIR", nil)
      ENV["HECKS_CACHE_DIR"] = dir
      FileUtils.mkdir_p(resident::Paths.directory, mode: 0o700)
      example.run
    ensure
      ENV["HECKS_CACHE_DIR"] = saved
    end
  end

  describe "the workers" do
    let(:gate) { Queue.new }
    let(:served) { Queue.new }

    # Starts two workers with `handle` replaced by the block; the callers are stand-ins.
    def work_with(&handled)
      allow(server).to receive(:handle, &handled)
      server.instance_variable_set(:@settings, { workers: 2.0 })
      server.send(:start_threads)
    end

    def serve_a_slow_caller_first
      work_with { |caller| caller == :slow ? gate.pop : served << caller }
      %i[slow quick].each { |caller| server.send(:enqueue, caller) }
    end

    after do
      server.instance_variable_set(:@retired, true)
      server.send(:join_threads)
    end

    it "takes a second caller while the first is still being served" do
      serve_a_slow_caller_first
      expect(Timeout.timeout(3) { served.pop }).to eq(:quick)
      gate << :go
    end

    it "drops, unread, a caller that waited in the queue longer than the launcher waits" do
      early = UNIXSocket.pair
      work_with { |caller| raise "should not be served: #{caller}" }
      allow(server).to receive(:now).and_return(0.0, 5.0)
      server.send(:enqueue, early.last)
      expect(early.first.wait_readable(3)).to be_truthy
    end
  end

  describe "the change check" do
    it "answers from the upkeep thread's last look when there is one, without looking" do
      server.instance_variable_set(:@fingerprint, instance_double(resident::Fingerprint))
      server.instance_variable_set(:@upkeep, Object.new)
      server.instance_variable_set(:@changed, true)
      expect(server.send(:changed?)).to be(true)
    end

    it "looks for itself when no upkeep thread runs" do
      server.instance_variable_set(:@fingerprint, instance_double(resident::Fingerprint, changed?: true))
      expect(server.send(:changed?)).to be(true)
    end
  end

  describe "being idle" do
    before { server.instance_variable_set(:@settings, { idle_seconds: 0.1 }) }

    it "is not idle while a caller is being served, however long ago the last line was", :aggregate_failures do
      server.instance_variable_set(:@active, Time.now - 60)
      expect(server.send(:idle?)).to be(true)
      server.send(:hold, UNIXSocket.pair.first)
      expect(server.send(:idle?)).to be(false)
    end
  end

  describe "a caller that was too slow" do
    let(:ends) { UNIXSocket.pair }

    it "is told dropped:deadline before the resident hangs up", :aggregate_failures do
      stub_const("Hecks::Adapters::Driving::Resident::Serving::HANDLE_WAIT", 0.2)
      server.instance_variable_set(:@fingerprint, instance_double(resident::Fingerprint, changed?: false))
      server.send(:handle, ends.last)
      expect(resident::Wire.read_reply(ends.first)).to eq("dropped:deadline")
      expect(ends.last).to be_closed
    end
  end

  describe "a forked child" do
    # Runs the child's side of a fork in this process, with the line itself and the process group
    # stood in for.
    def become_child_with(own, others)
      stand_in_the_line
      server.send(:become_child, UNIXSocket.pair.first, {}, [own], IO.pipe, others)
    end

    def stand_in_the_line
      allow(resident::Worker).to receive(:new).and_return(instance_double(resident::Worker, run: nil))
      allow(server).to receive(:into_group)
      %w[@server @lock].each { |name| server.instance_variable_set(name, UNIXSocket.pair.first) }
    end

    it "closes every other caller's socket and stream it inherited, and keeps its own" do
      other = UNIXSocket.pair.first
      own = UNIXSocket.pair.first
      become_child_with(own, [other])
      expect([other.closed?, own.closed?]).to eq([true, false])
    end
  end

  describe "the wait for a busy resident" do
    # Asks a resident that takes the connection and never answers; the answer and the seconds
    # the launcher waited.
    def asked_of_a_silent_resident
      listener = UNIXServer.new(resident::Paths.socket("/c"))
      File.chmod(0o600, resident::Paths.socket("/c"))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      answer = client.ask("/c", script)
      [answer, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    ensure
      listener&.close
    end

    it "is the world's ready_wait_ms once a resident has written it" do
      resident::Paths.remember("ready_wait_ms", 250)
      expect(client.ready_wait).to eq(0.25)
    end

    it "is 0.4 seconds until one has" do
      expect(client.ready_wait).to eq(0.4)
    end

    it "ends a launcher's wait for a resident that never answers in about that time" do
      answer, waited = asked_of_a_silent_resident
      expect([answer, waited.between?(0.3, 1.5)]).to eq([[nil, "busy"], true])
    end
  end

  describe "starting the replacement" do
    let(:root) { "/c" }

    it "lets one launcher claim the start and the rest boot on their own", :aggregate_failures do
      expect(claim.take?(root)).to be(true)
      expect(claim.take?(root)).to be(false)
    end

    it "lets another launcher take over a claim whose resident never came" do
      claim.take?(root)
      File.utime(Time.now - 60, Time.now - 60, resident::Paths.claim(root))
      expect(claim.take?(root)).to be(true)
    end

    it "does not start a second resident while one is claimed", :aggregate_failures do
      allow(Process).to receive(:spawn)
      claim.take?(root)
      expect(client.spawn_resident(root, script)).to eq("none")
      expect(Process).not_to have_received(:spawn)
    end

    it "is cleared by the resident that holds the lock" do
      claim.take?(root)
      resident::Server.new(root, "/c/exe/hecks").send(:lock_taken?)
      expect(File.exist?(resident::Paths.claim(root))).to be(false)
    end
  end
end

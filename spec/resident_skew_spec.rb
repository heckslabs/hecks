require "spec_helper"
require "socket"
require "tmpdir"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/client"

# A resident and a launcher that speak different protocols (ADR 0201): the files are named for
# the protocol, so the launcher never talks to the old resident and starts its own; a resident
# too busy to answer twice in a row is stopped; and a resident that no caller can use still goes
# idle. No process starts: the system's process table and signals are stood in for.
RSpec.describe "a resident of another protocol" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:paths) { resident::Paths }

  around do |example|
    Dir.mktmpdir("hrk") do |dir|
      saved = ENV.to_h.slice("HECKS_CACHE_DIR", "HECKS_RESIDENT_PROTOCOL")
      ENV["HECKS_CACHE_DIR"] = dir
      ENV.delete("HECKS_RESIDENT_PROTOCOL")
      FileUtils.mkdir_p(paths.directory, mode: 0o700)
      example.run
    ensure
      ENV.delete("HECKS_RESIDENT_PROTOCOL")
      ENV.update(saved)
    end
  end

  def root = "/checkout"

  def stuck = resident::Stuck

  def holding(file)
    lock = File.new(file, File::CREAT | File::RDWR)
    lock.flock(File::LOCK_EX)
    lock
  end

  def under_protocol(number)
    ENV["HECKS_RESIDENT_PROTOCOL"] = number
    yield
  ensure
    ENV.delete("HECKS_RESIDENT_PROTOCOL")
  end

  def other_lock(checkout = root) = under_protocol("2") { paths.lock(checkout) }

  describe "the files' names" do
    it "carry the protocol, so one protocol's files are never another's", :aggregate_failures do
      other = under_protocol("2") { paths.socket(root) }
      expect(paths.socket(root)).to end_with("-p#{resident::Wire::PROTOCOL}.sock")
      expect([paths.lock(root), paths.pid(root), paths.version(root)]).to all(include("-p#{resident::Wire::PROTOCOL}."))
      expect(other).not_to eq(paths.socket(root))
    end

    it "share the checkout's part, so a resident of another protocol is found", :aggregate_failures do
      expect(other_lock).to start_with(paths.prefix(root))
      expect(File.basename(paths.lock(root))).to match(/\A\h{8}-p\d+\.lock\z/)
    end
  end

  describe "finding a resident of another protocol" do
    it "finds one that holds a lock of the checkout's, not of this protocol", :aggregate_failures do
      old = holding(other_lock)
      expect(paths.other_protocol?(root)).to be(true)
      expect(paths.absent_reason(root)).to eq("protocol")
      old.close
    end

    it "does not count its own protocol's lock, a lock nobody holds, or another checkout's", :aggregate_failures do
      held = [holding(paths.lock(root)), holding(other_lock("/elsewhere"))]
      FileUtils.touch(other_lock)
      expect(paths.other_protocol?(root)).to be(false)
      expect(paths.absent_reason(root)).to be_nil
      held.each(&:close)
    end

    it "is not asked: the launcher notes protocol and does not connect", :aggregate_failures do
      old = holding(other_lock)
      allow(UNIXSocket).to receive(:new)
      expect(resident::Client.ask(root, "/checkout/exe/hecks")).to eq([nil, "protocol"])
      expect(UNIXSocket).not_to have_received(:new)
      old.close
    end
  end

  describe "a resident too busy to answer twice in a row" do
    def stopped = (@stopped ||= [])

    def ours = [Process.uid, "ruby -I lib lib/x/resident/server.rb #{root} #{root}/exe/hecks"]

    def stopper = ->(pid) { stopped << pid }

    def busy(found = ours) = stuck.after(root, "busy", look: ->(_pid) { found }, stop: stopper)

    before { File.write(paths.pid(root), "4242") }

    it "is left alone the first time, and noted", :aggregate_failures do
      expect(busy).to be(false)
      expect([stopped, File.exist?(paths.busy(root))]).to eq([[], true])
    end

    it "is stopped the second time, within the minute, and the note is cleared", :aggregate_failures do
      busy
      expect(busy).to be(true)
      expect([stopped, File.exist?(paths.busy(root))]).to eq([[4242], false])
    end

    it "is not stopped when a line it served came between", :aggregate_failures do
      busy
      stuck.after(root, nil, look: ->(_pid) { ours }, stop: stopper)
      expect(busy).to be(false)
      expect(stopped).to be_empty
    end

    it "is not stopped when the first busy was long ago" do
      busy
      old = Time.now - (stuck::STREAK + 5)
      File.utime(old, old, paths.busy(root))
      expect(busy).to be(false)
    end

    it "is not stopped when the process is another user's", :aggregate_failures do
      busy
      expect(busy([Process.uid + 1, ours.last])).to be(false)
      expect(stopped).to be_empty
    end

    it "is not stopped when the process is not this checkout's resident", :aggregate_failures do
      busy
      expect(busy([Process.uid, "vim notes.txt #{root}"])).to be(false)
      expect(stopped).to be_empty
    end

    it "is not stopped when the process id names no process" do
      busy
      expect(busy(nil)).to be(false)
    end

    it "is not stopped when there is no process id file", :aggregate_failures do
      File.delete(paths.pid(root))
      busy
      expect(busy).to be(false)
      expect(stopped).to be_empty
    end
  end

  describe "a resident that no caller can use" do
    let(:server) { resident::Server.new(root, "#{root}/exe/hecks") }

    before do
      server.instance_variable_set(:@settings, { idle_seconds: 0.2 })
      server.instance_variable_set(:@active, Time.now - 5)
      allow(resident::Peer).to receive(:trusted?).and_return(false)
    end

    it "does not count a caller that fails the handshake as use, so it goes idle", :aggregate_failures do
      expect(server.send(:idle?)).to be(true)
      server.send(:handle, UNIXSocket.pair.first)
      expect(server.send(:idle?)).to be(true)
    end

    it "still goes idle after any number of failing callers" do
      3.times { server.send(:handle, UNIXSocket.pair.first) }
      expect(server.send(:idle?)).to be(true)
    end
  end
end

require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"
require_relative "support/thread_parking"

# The decisions inside a resident that need no process: how many others stand, when it is idle,
# and when it will not serve a line (ADR 0201). The processes themselves are in
# resident_launcher_spec.rb.
RSpec.describe Hecks::Adapters::Driving::Resident::Server do
  let(:paths) { Hecks::Adapters::Driving::Resident::Paths }
  let(:server) { described_class.new("/checkout", "/checkout/exe/hecks") }

  around do |example|
    Dir.mktmpdir("hrs") do |dir|
      saved = ENV.fetch("HECKS_CACHE_DIR", nil)
      ENV["HECKS_CACHE_DIR"] = dir
      FileUtils.mkdir_p(paths.directory)
      example.run
    ensure
      ENV["HECKS_CACHE_DIR"] = saved
    end
  end

  def holding(root)
    lock = File.new(paths.lock(root), File::CREAT | File::RDWR)
    lock.flock(File::LOCK_EX)
    lock
  end

  describe "counting the residents that stand" do
    it "counts the locks other residents hold, not its own and not a lock nobody holds", :aggregate_failures do
      held = [holding("/a"), holding("/b"), holding("/checkout")]
      FileUtils.touch(paths.lock("/idle"))
      expect(server.send(:standing)).to eq(2)
      held.each(&:close)
    end

    it "counts none when no other resident has a lock" do
      expect(server.send(:standing)).to eq(0)
    end
  end

  describe "being idle" do
    before { server.instance_variable_set(:@settings, { idle_seconds: 0.5 }) }

    def waited(seconds, monitors: [])
      server.instance_variable_set(:@monitors, monitors)
      server.instance_variable_set(:@active, Time.now - seconds)
      server.send(:idle?)
    end

    it "is idle once nothing has been asked for longer than the world says" do
      expect(waited(1)).to be(true)
    end

    it "is not idle before that" do
      expect(waited(0.1)).to be(false)
    end

    it "is not idle while a line it started is still running" do
      running = Thread.new { Thread.stop }
      ThreadParking.wait_until_parked(running)
      expect(waited(10, monitors: [running])).to be(false)
      running.kill
    end
  end

  describe "an orphaned resident" do
    let(:there) { { "/checkout" => true } }
    let(:orphan) { described_class.new("/checkout", "/checkout/exe/hecks", exists: ->(path) { there.fetch(path, false) }) }

    before { there[paths.socket("/checkout")] = true }

    it "is not orphaned while its checkout and its socket stand" do
      expect(orphan.send(:orphaned?)).to be(false)
    end

    it "is orphaned once its checkout directory is gone" do
      there.delete("/checkout")
      expect(orphan.send(:orphaned?)).to be(true)
    end

    it "is orphaned once its socket is gone, as when the cache was cleared" do
      there.delete(paths.socket("/checkout"))
      expect(orphan.send(:orphaned?)).to be(true)
    end

    it "stays up on a quiet second while its checkout stands" do
      allow(orphan).to receive(:retire)
      orphan.send(:retire_when_orphaned)
      expect(orphan).not_to have_received(:retire)
    end

    it "retires on a quiet second once its checkout is gone" do
      allow(orphan).to receive(:retire)
      there.delete("/checkout")
      orphan.send(:retire_when_orphaned)
      expect(orphan).to have_received(:retire).once
    end
  end

  describe "serving a line" do
    let(:fingerprint) { instance_double(Hecks::Adapters::Driving::Resident::Fingerprint, changed?: false) }
    let(:listener) { instance_double(UNIXServer, closed?: false, close: nil) }
    let(:request) { { env: { "HOME" => "/home/a" }, script: "/checkout/exe/hecks" } }

    before do
      server.instance_variable_set(:@fingerprint, fingerprint)
      server.instance_variable_set(:@environment, { "HOME" => "/home/a" })
      server.instance_variable_set(:@server, listener)
    end

    it "serves a line made with the environment it loaded under while its code is as loaded" do
      expect(server.send(:servable?, request)).to be(true)
    end

    it "does not serve a line made with another home or bundle, and stays up", :aggregate_failures do
      expect(server.send(:servable?, request.merge(env: { "HOME" => "/home/b" }))).to be(false)
      expect(server.instance_variable_get(:@retired)).to be_nil
    end

    it "retires, and refuses the line, when the code is not as it was loaded", :aggregate_failures do
      allow(fingerprint).to receive(:changed?).and_return(true)
      expect(server.send(:servable?, request)).to be(false)
      expect(server.instance_variable_get(:@retired)).to be(true)
    end
  end
end

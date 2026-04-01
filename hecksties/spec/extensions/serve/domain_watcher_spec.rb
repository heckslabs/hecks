require "spec_helper"
require "hecks/extensions/serve/domain_watcher"
require "tmpdir"
require "fileutils"

RSpec.describe Hecks::HTTP::DomainWatcher do
  let(:tmpdir) { Dir.mktmpdir("watcher_test") }
  let(:changes) { [] }
  let(:watcher) do
    described_class.new(tmpdir, interval: 0.02) { changes << Time.now }
  end

  after do
    watcher.stop if watcher.running?
    FileUtils.rm_rf(tmpdir)
  end

  describe "#start / #stop" do
    it "starts and stops the polling thread" do
      watcher.start
      expect(watcher.running?).to be true
      watcher.stop
      expect(watcher.running?).to be false
    end
  end

  describe "change detection" do
    it "fires callback when a Ruby file is added" do
      watcher.start
      sleep 0.01
      File.write(File.join(tmpdir, "new_file.rb"), "# new")
      sleep 0.08
      watcher.stop
      expect(changes).not_to be_empty
    end

    it "fires callback when a Ruby file is modified" do
      path = File.join(tmpdir, "existing.rb")
      File.write(path, "# v1")
      watcher.start
      sleep 0.01
      File.write(path, "# v2")
      sleep 0.08
      watcher.stop
      expect(changes).not_to be_empty
    end

    it "does not fire when no files change" do
      File.write(File.join(tmpdir, "stable.rb"), "# stable")
      watcher.start
      sleep 0.08
      watcher.stop
      expect(changes).to be_empty
    end

    it "ignores non-Ruby files" do
      watcher.start
      sleep 0.01
      File.write(File.join(tmpdir, "notes.txt"), "not ruby")
      sleep 0.08
      watcher.stop
      expect(changes).to be_empty
    end
  end

  describe "#running?" do
    it "returns false before start" do
      expect(watcher.running?).to be false
    end
  end
end

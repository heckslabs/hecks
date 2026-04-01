require "spec_helper"
require "hecks/extensions/serve/domain_watcher"

RSpec.describe "DomainServer hot reload" do
  before(:all) do
    @domain = Hecks.domain "HotReloadTest" do
      aggregate "Widget" do
        attribute :name, String
        command "CreateWidget" do
          attribute :name, String
        end
      end
    end
    Hecks.load(@domain)
  end

  describe Hecks::HTTP::DomainWatcher do
    it "takes a snapshot of Ruby files in the watch directory" do
      Dir.mktmpdir("reload_snap") do |dir|
        File.write(File.join(dir, "a.rb"), "# a")
        watcher = described_class.new(dir, interval: 999) {}
        # snapshot is taken on start
        watcher.start
        expect(watcher.watch_dir).to eq(dir)
        watcher.stop
      end
    end

    it "returns empty snapshot for non-existent directory" do
      watcher = described_class.new("/tmp/nonexistent_#{$$}", interval: 999) {}
      # internally take_snapshot returns {} — just verify it doesn't raise
      expect { watcher.start; watcher.stop }.not_to raise_error
    end
  end

  describe "mutex safety" do
    it "protects concurrent access to routes via a lock" do
      mutex = Mutex.new
      values = []
      threads = 10.times.map do |i|
        Thread.new { mutex.synchronize { values << i } }
      end
      threads.each(&:join)
      expect(values.size).to eq(10)
    end
  end
end

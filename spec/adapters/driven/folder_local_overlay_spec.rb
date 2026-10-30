require "spec_helper"
require "tmpdir"

# A copy's own overlay loads after the domain's files and before a named environment: first
# `environments/local.*`, then `*.local.world` beside the domain and in the working directory, so
# one copy can name its own database and `HECKS_ENVIRONMENT=memory` still wins.
RSpec.describe Hecks::Adapters::Folder do
  let(:folder) { described_class.new }
  let(:loaded) { [] }

  describe "#load_overlay" do
    before do
      allow(Dir).to receive(:pwd).and_return("/work")
      allow(folder).to receive(:load_each) { |dir, patterns| loaded << [dir, *patterns] }
    end

    def local_files = ["/domain", "environments/local.hecksagon", "environments/local.world"]

    def memory_files = ["/domain", "environments/memory.hecksagon", "environments/memory.world"]

    def local_worlds
      %w[/domain /work].map { |where| [where, *Hecks::Adapters::FolderOverlay::LOCAL_FILES] }
    end

    it "loads the copy's overlay, then the local files here and in the working directory" do
      folder.load_overlay("/domain", nil)
      expect(loaded).to eq([local_files, *local_worlds])
    end

    it "loads the named environment last" do
      folder.load_overlay("/domain", "memory")
      expect(loaded).to eq([local_files, *local_worlds, memory_files])
    end

    it "loads the local overlay once when the environment is local" do
      folder.load_overlay("/domain", "local")
      expect(loaded).to eq([local_files, *local_worlds])
    end

    it "loads the local files once when the working directory is the domain's" do
      allow(Dir).to receive(:pwd).and_return("/domain")
      folder.load_overlay("/domain", nil)
      expect(loaded).to eq([local_files, local_worlds.first])
    end
  end

  describe "#load_each" do
    def load_from(directory, pattern)
      allow(folder).to receive(:load_file) { |file| loaded << File.basename(file) }
      folder.send(:load_each, directory, [pattern])
      loaded
    end

    def directory_with(*names)
      Dir.mktmpdir.tap { |dir| names.each { |name| File.write(File.join(dir, name), "") } }
    end

    it "leaves a local world out of a base glob, so the overlay phase loads it after the base" do
      expect(load_from(directory_with("a.world", "a.local.world"), "*.world")).to eq(["a.world"])
    end

    it "leaves a local hecksagon out of a base glob" do
      expect(load_from(directory_with("a.hecksagon", "a.local.hecksagon"), "*.hecksagon")).to eq(["a.hecksagon"])
    end

    it "loads a local file when its own pattern asks for it" do
      expect(load_from(directory_with("a.hecksagon", "a.local.hecksagon"), "*.local.hecksagon")).to eq(["a.local.hecksagon"])
    end
  end
end

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "tempfile"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/client"

# What a resident-served line does not pay for (ADR 0201, "The warm path"): the declaration
# checks it shares, the stores it does not read, the heap walk at its end, and the standard library
# its launcher never uses.
RSpec.describe "the resident's warm path" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:worker) { resident::Worker }

  describe "a read-only boot" do
    let(:loader) { Hecks::Runtime::Loader }
    let(:described) { instance_double(Hecks::Runtime::Loader::Described, registry: :registry, directory: "d") }

    before do
      allow(loader).to receive_messages(run_boot_gates!: nil, dispatcher_for: :dispatcher)
      allow(loader).to receive(:redrive_outbox!)
    end

    it "opens no store and checks no saga for the gates" do
      loader.boot_described(described, read_only: true)
      expect(loader).to have_received(:run_boot_gates!).with(:registry, "d", open_stores: false)
    end

    it "redrives nothing" do
      loader.boot_described(described, read_only: true)
      expect(loader).not_to have_received(:redrive_outbox!)
    end

    it "opens the stores for a boot that acts" do
      allow(loader).to receive_messages(redrive_sagas!: nil, seed_privacy_markings!: nil)
      loader.boot_described(described)
      expect(loader).to have_received(:run_boot_gates!).with(:registry, "d", open_stores: true)
    end
  end

  describe "the domains a resident loads" do
    let(:cache) { resident::DescribedCache.new }
    let(:registry) { instance_double(Hecks::Runtime::Registry, verify_declarations!: nil) }
    let(:described) { instance_double(Hecks::Runtime::Loader::Described, registry: registry) }

    before { allow(Hecks).to receive(:describe).and_return(described) }

    it "has their declaration checks run once, before any child forks" do
      cache.load("/domain", nil)
      expect(registry).to have_received(:verify_declarations!).once
    end

    it "holds a domain that fails them, for each child to refuse in its own words" do
      allow(registry).to receive(:verify_declarations!).and_raise(Hecks::Runtime::WiringError, "no")
      expect(cache.load("/domain", nil)).to be(described)
    end
  end

  describe "a child's temporary files" do
    let(:made) { Class.new { def self.new(*) = Object.new } }

    before do
      worker.instance_variable_set(:@tempfiles, [])
      made.singleton_class.prepend(worker::Tempfiles)
    end

    it "are recorded as they are made" do
      file = made.new
      expect(worker.tempfiles).to eq([file])
    end

    it "are the only ones closed at its end, without walking the heap" do
      worker.tempfiles << instance_double(Tempfile, close!: nil)
      allow(Process).to receive(:exit!)
      allow(ObjectSpace).to receive(:each_object)
      worker.leave
      expect(ObjectSpace).not_to have_received(:each_object)
    end

    it "close without trouble when one is already gone" do
      file = instance_double(Tempfile)
      allow(file).to receive(:close!).and_raise(Errno::ENOENT)
      expect(worker.close_quietly(file)).to be_nil
    end
  end

  describe "the launcher's client" do
    let(:dir) { Dir.mktmpdir }
    let(:loaded) do
      <<~'RUBY'
        require "hecks/adapters/driving/resident/client"
        puts %w[fileutils tmpdir].select { |n| $LOADED_FEATURES.any? { |f| f.end_with?("/#{n}.rb") } }.join(",")
      RUBY
    end

    after { FileUtils.rm_rf(dir) }

    it "forgets a file that is there" do
      path = File.join(dir, "busy")
      File.write(path, "")
      resident::Paths.forget(path)
      expect(File.exist?(path)).to be(false)
    end

    it "forgets a file that is not there without trouble" do
      expect(resident::Paths.forget(File.join(dir, "none"))).to be_nil
    end

    it "loads no fileutils or tmpdir until it starts a resident" do
      lib = File.expand_path("../lib", __dir__)
      out, = Open3.capture2({ "PATH" => ENV.fetch("PATH"), "HOME" => Dir.home }, RbConfig.ruby, "-I", lib, "-e", loaded,
                            unsetenv_others: true)
      expect(out.strip).to eq("")
    end
  end

  describe "the trace" do
    it "prints nothing unless a line asks for it" do
      expect { resident::Trace.mark("x") }.not_to output.to_stderr
    end

    it "prints a mark on the wall clock when asked" do
      allow(ENV).to receive(:key?).with("HECKS_TRACE_TIMING").and_return(true)
      expect { resident::Trace.mark("x") }.to output(/\ATRACE x \d+\.\d\n\z/).to_stderr
    end
  end
end

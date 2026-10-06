require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks"
require "hecks/fuzzing"
require "hecks/rust_build/conformance_fuzz"

# The conformance fuzz keeps its scripts in a scratch directory of its own, never in the gem.
RSpec.describe Hecks::RustBuild::ConformanceFuzz do
  let(:cache) { Dir.mktmpdir("fuzz_cache") }
  let(:root) { File.join(Hecks::RustBuild::ROOT, "tmp", "rust_conformance_fuzz") }

  before do
    allow(Hecks::CacheDir).to receive(:path).with("rust_conformance_fuzz").and_return(File.join(cache, "fuzz"))
    allow(Hecks::Fuzzing::SequenceGenerator).to receive(:generate).and_return([])
    allow(Hecks::RustBuild::Conformance).to receive(:call).and_return(0)
  end

  after { FileUtils.rm_rf(cache) }

  it "refuses a domain whose basename could name the wrong directory", :aggregate_failures do
    %w[.. . domains/.. a/b/.].each do |domain|
      expect { described_class.call([domain, "native", "1", "1"]) }
        .to raise_error(Hecks::RustBuild::Failure, /not a domain directory name/)
    end
    expect(Dir.exist?(File.join(cache, "fuzz"))).to be(false)
  end

  # Stubs the conformance run to answer `status`, and answers the array that collects the script
  # path each call was given.
  def record_scripts(status)
    [].tap { |paths| allow(Hecks::RustBuild::Conformance).to receive(:call) { |args| (paths << args[1]) && status } }
  end

  it "runs in a fresh directory under the cache root and removes it when every seed matched", :aggregate_failures do
    seen = record_scripts(0)

    expect { described_class.call(["examples/pizzas", "native", "2", "1"]) }.to output(/all matched/).to_stdout
    expect(seen.map { |path| File.dirname(path) }.uniq.size).to eq(1)
    expect(seen.first).to start_with(File.join(cache, "fuzz", "pizzas-"))
    expect(Dir.children(File.join(cache, "fuzz"))).to be_empty
  end

  it "gives two runs different directories", :aggregate_failures do
    scripts = record_scripts(1)

    2.times { expect { described_class.call(["examples/pizzas", "native", "1", "1"]) }.to raise_error(Hecks::RustBuild::Failure) }

    expect(scripts.map { |path| File.dirname(path) }.uniq.size).to eq(2)
  end

  it "keeps the failing seed's script so it can be replayed", :aggregate_failures do
    allow(Hecks::RustBuild::Conformance).to receive(:call).and_return(1)

    expect { described_class.call(["examples/pizzas", "native", "1", "1"]) }
      .to raise_error(Hecks::RustBuild::Failure, %r{reproduce with: .*#{Regexp.escape(cache)}/fuzz/pizzas-.*seed-1\.json})
    expect(Dir.glob(File.join(cache, "fuzz", "pizzas-*", "seed-1.json")).size).to eq(1)
  end

  it "never writes into the gem's own tmp/", :aggregate_failures do
    before_entries = Dir.exist?(root) ? Dir.children(root).sort : nil

    expect { described_class.call(["examples/pizzas", "native", "1", "1"]) }.to output.to_stdout

    # Compared with what was there before, so a directory an older checkout left behind
    # does not fail the run; only a write made by this call does.
    expect(Dir.exist?(root) ? Dir.children(root).sort : nil).to eq(before_entries)
  end
end

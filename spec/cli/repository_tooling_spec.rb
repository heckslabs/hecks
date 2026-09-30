require "spec_helper"
require "tmpdir"
require "json"
require "stringio"
require "hecks/cli/canonicalise"
require "hecks/cli/doc_coverage"
require "hecks/cli/expression_projection"
require "hecks/cli/pattern_cases"
require "hecks/cli/release"
require "hecks/cli/release_gem"
require "hecks/cli/rspec_io_parallel_files"
require "hecks/cli/rspec_shard_files"
require "hecks/cli/seed_semantics_corpus"
require "hecks/cli/stress_concurrency_specs"

# The bodies of the repository's small `bin/` scripts live in `Hecks::CLI`; each returns its
# exit status and takes the streams it writes to.
RSpec.describe "the repository tooling commands" do
  def expect_abort_with(message, &block)
    expect { expect(&block).to raise_error(SystemExit) { |error| expect(error.status).to eq(1) } }
      .to output(message).to_stderr
  end

  describe Hecks::CLI::Canonicalise do
    it "prints a JSON document with its keys sorted" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "a.json")
        File.write(path, '{"b":1,"a":{"d":1,"c":2}}')
        out = StringIO.new

        expect(described_class.call([path], out: out)).to eq(0)
        expect(JSON.parse(out.string).keys).to eq(%w[a b])
        expect(out.string.index('"c"')).to be < out.string.index('"d"')
      end
    end
  end

  describe Hecks::CLI::PatternCases do
    it "records one row per pattern and input, and is what the committed cases hold" do
      out = StringIO.new
      described_class.call(out: out)

      committed = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/fixtures/patterns.json")))
      expect(JSON.parse(out.string)).to eq(committed)
    end
  end

  describe Hecks::CLI::DocCoverage do
    it "is clean for this repository's reference pages" do
      out = StringIO.new

      expect(described_class.call(root: InMemoryDomain::ROOT, out: out, err: StringIO.new)).to eq(0)
    end
  end

  describe Hecks::CLI::ExpressionProjection do
    it "prints the committed projection with --stdout and writes nothing" do
      out = StringIO.new
      path = File.join(InMemoryDomain::ROOT, "lib/hecks/bluebook/expression/projection.json")
      before = File.read(path)

      expect(described_class.call(["--stdout"], out: out)).to eq(0)
      expect(out.string).to eq(before)
      expect(File.read(path)).to eq(before)
    end
  end

  describe Hecks::CLI::Release do
    it "prints its usage and exits 0 for --help" do
      expect { @status = described_class.call(["--help"], root: Dir.pwd) }.to output(%r{Usage: bin/release}).to_stdout
      expect(@status).to eq(0)
    end

    it "exits 2 with the usage for a flag it does not know" do
      status = nil
      expect { status = described_class.call(["--frobnicate"], root: Dir.pwd) }
        .to output(%r{--frobnicate.*Usage: bin/release}m).to_stderr
      expect(status).to eq(2)
    end
  end

  describe Hecks::CLI::ReleaseGem do
    it "refuses, pushing nothing, when the JS client is at another version" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "packages/hecks-client"))
        File.write(File.join(dir, "packages/hecks-client/package.json"), '{"version":"0.0.1"}')
        commands = Object.new
        def commands.capture(*) = Struct.new(:success?, :out, :status).new(true, "", 0)
        vault = instance_double(Hecks::Adapters::Codebase::SecretVault, installed?: true)
        allow(Hecks::Adapters::Codebase::SecretVault).to receive(:new).and_return(vault)
        err = StringIO.new

        expect(described_class.call(root: dir, commands: commands, out: StringIO.new, err: err)).to eq(1)
        expect(err.string).to include("packages/hecks-client is at 0.0.1", Hecks::VERSION)
      end
    end

    it "refuses when 1Password's CLI is not installed" do
      Dir.mktmpdir do |dir|
        vault = instance_double(Hecks::Adapters::Codebase::SecretVault, installed?: false)
        allow(Hecks::Adapters::Codebase::SecretVault).to receive(:new).and_return(vault)
        err = StringIO.new

        expect(described_class.call(root: dir, commands: Object.new, out: StringIO.new, err: err)).to eq(1)
        expect(err.string).to include("1Password CLI (op) not found")
      end
    end
  end

  describe Hecks::CLI::RspecShardFiles do
    let(:root) { InMemoryDomain::ROOT }

    it "splits the spec files so every file lands in exactly one group" do
      groups = (1..3).map do |group|
        out = StringIO.new
        described_class.call([group.to_s, "3"], root: root, out: out, err: StringIO.new)
        out.string.lines.map(&:chomp)
      end

      expect(groups.flatten.sort).to eq(Dir.glob("spec/**/*_spec.rb", base: root).sort)
      expect(groups.map(&:size).min).to be > 0
    end

    it "refuses a group outside the split" do
      expect_abort_with(/group must be between 1 and 3, got 4/) { described_class.call(%w[4 3], root: root) }
    end
  end

  describe Hecks::CLI::RspecIoParallelFiles do
    it "refuses a command line with no tag arguments" do
      expect_abort_with(%r{usage: bin/rspec_io_parallel_files}) do
        described_class.call(["^spec/qa"], root: InMemoryDomain::ROOT)
      end
    end

    it "refuses an exclude pattern that leaves no candidate files" do
      expect_abort_with(/ZERO candidate spec files/) do
        described_class.call([".", "--", "--tag", "io"], root: InMemoryDomain::ROOT)
      end
    end

    it "names what a stale committed list is missing and what it lists in vain" do
      Dir.mktmpdir do |dir|
        list = File.join(dir, "list.txt")
        File.write(list, "spec/gone_spec.rb\n")
        err = StringIO.new

        expect { described_class.check(["spec/new_spec.rb"], list, "list.txt", "^x", ["--tag", "io"], err) }
          .to raise_error(SystemExit)
        expect(err.string).to include("list.txt is out of date.", "spec/new_spec.rb", "spec/gone_spec.rb")
      end
    end
  end

  describe Hecks::CLI::StressConcurrencySpecs do
    it "prints its usage for --help and stops" do
      out = StringIO.new

      expect(described_class.call(["--help"], root: Dir.pwd, out: out)).to eq(0)
      expect(out.string).to include("Usage: bin/stress_concurrency_specs")
    end

    it "exits 64 for an argument it does not know" do
      status = nil
      expect { status = described_class.call(["--nope"], root: Dir.pwd, out: StringIO.new) }
        .to output(/unrecognized argument: "--nope"/).to_stderr
      expect(status).to eq(64)
    end
  end

  describe Hecks::CLI::SeedSemanticsCorpus do
    it "seeds nothing when every fixture already carries its expect" do
      out = StringIO.new

      expect(described_class.call(root: InMemoryDomain::ROOT, env: {}, out: out)).to eq(0)
      expect(out.string).to start_with("nothing to seed")
    end
  end
end

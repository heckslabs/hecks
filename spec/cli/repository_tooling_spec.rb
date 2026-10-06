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
    around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

    # @return [Array(Integer, String)] the exit status and what was printed for a file holding the JSON
    def canonicalised(json)
      path = File.join(@dir, "a.json")
      File.write(path, json)
      out = StringIO.new
      [described_class.call([path], out: out), out.string]
    end

    it "prints a JSON document with its keys sorted", :aggregate_failures do
      status, printed = canonicalised('{"b":1,"a":{"d":1,"c":2}}')

      expect(status).to eq(0)
      expect(JSON.parse(printed).keys).to eq(%w[a b])
      expect(printed.index('"c"')).to be < printed.index('"d"')
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
    let(:path) { File.join(InMemoryDomain::ROOT, "lib/hecks/bluebook/expression/projection.json") }

    it "prints the committed projection with --stdout and writes nothing", :aggregate_failures do
      out = StringIO.new
      before = File.read(path)

      expect(described_class.call(["--stdout"], out: out)).to eq(0)
      expect(out.string).to eq(before)
      expect(File.read(path)).to eq(before)
    end
  end

  describe Hecks::CLI::Release do
    it "prints its usage and exits 0 for --help", :aggregate_failures do
      expect { @status = described_class.call(["--help"], root: Dir.pwd) }.to output(/Usage: hecks publish/).to_stdout
      expect(@status).to eq(0)
    end

    it "exits 2 with the usage for a flag it does not know", :aggregate_failures do
      status = nil
      expect { status = described_class.call(["--frobnicate"], root: Dir.pwd) }
        .to output(/--frobnicate.*Usage: hecks publish/m).to_stderr
      expect(status).to eq(2)
    end
  end

  describe Hecks::CLI::ReleaseGem do
    around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

    def stub_vault(installed:)
      vault = instance_double(Hecks::Adapters::Codebase::SecretVault, installed?: installed)
      allow(Hecks::Adapters::Codebase::SecretVault).to receive(:new).and_return(vault)
    end

    # @return [Array(Integer, String)] the exit status and what was written to stderr
    def released_with(commands)
      err = StringIO.new
      [described_class.call(root: @dir, commands: commands, out: StringIO.new, err: err), err.string]
    end

    def client_at(version)
      FileUtils.mkdir_p(File.join(@dir, "packages/hecks-client"))
      File.write(File.join(@dir, "packages/hecks-client/package.json"), %({"version":"#{version}"}))
    end

    def succeeding_commands
      commands = Object.new
      def commands.capture(*) = Struct.new(:success?, :out, :status).new(true, "", 0)
      commands
    end

    it "refuses, pushing nothing, when the JS client is at another version", :aggregate_failures do
      client_at("0.0.1")
      stub_vault(installed: true)
      status, err = released_with(succeeding_commands)

      expect(status).to eq(1)
      expect(err).to include("packages/hecks-client is at 0.0.1", Hecks::VERSION)
    end

    it "refuses when 1Password's CLI is not installed", :aggregate_failures do
      stub_vault(installed: false)
      status, err = released_with(Object.new)

      expect(status).to eq(1)
      expect(err).to include("1Password CLI (op) not found")
    end
  end

  describe Hecks::CLI::RspecShardFiles do
    let(:root) { InMemoryDomain::ROOT }

    # @return [Array<String>] the spec files the group of a three-way split holds
    def shard(group)
      out = StringIO.new
      described_class.call([group.to_s, "3"], root: root, out: out, err: StringIO.new)
      out.string.lines.map(&:chomp)
    end

    it "splits the spec files so every file lands in exactly one group", :aggregate_failures do
      groups = (1..3).map { |group| shard(group) }

      expect(groups.flatten.sort).to eq(Dir.glob("spec/**/*_spec.rb", base: root).sort)
      expect(groups.map(&:size).min).to be > 0
    end

    it "refuses a group outside the split" do
      expect_abort_with(/group must be between 1 and 3, got 4/) { described_class.call(%w[4 3], root: root) }
    end
  end

  describe Hecks::CLI::RspecIoParallelFiles do
    around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

    it "refuses a command line with no tag arguments" do
      expect_abort_with(/usage: hecks list_io_parallel_specs/) do
        described_class.call(["^spec/qa"], root: InMemoryDomain::ROOT)
      end
    end

    it "refuses an exclude pattern that leaves no candidate files" do
      expect_abort_with(/ZERO candidate spec files/) do
        described_class.call([".", "--", "--tag", "io"], root: InMemoryDomain::ROOT)
      end
    end

    # Checks a committed list naming a file that is gone against a candidate list naming a new one.
    def check_stale_list(err)
      File.write(File.join(@dir, "list.txt"), "spec/gone_spec.rb\n")
      request = described_class::Request.new("--check", "list.txt", "^x", ["--tag", "io"], @dir, StringIO.new, err)
      described_class.check(["spec/new_spec.rb"], request)
    end

    it "names what a stale committed list is missing and what it lists in vain", :aggregate_failures do
      err = StringIO.new

      expect { check_stale_list(err) }.to raise_error(SystemExit)
      expect(err.string).to include("list.txt is out of date.", "spec/new_spec.rb", "spec/gone_spec.rb")
    end
  end

  describe Hecks::CLI::StressConcurrencySpecs do
    it "prints its usage for --help and stops", :aggregate_failures do
      out = StringIO.new

      expect(described_class.call(["--help"], root: Dir.pwd, out: out)).to eq(0)
      expect(out.string).to include("Usage: hecks stress_concurrency")
    end

    it "exits 64 when the run count and first seed are not given, since the verb supplies them", :aggregate_failures do
      status = nil
      expect { status = described_class.call(["--parallel", "1"], root: Dir.pwd, out: StringIO.new) }
        .to output(/missing --runs, --seed-start/).to_stderr
      expect(status).to eq(64)
    end

    it "exits 64 for an argument it does not know", :aggregate_failures do
      status = nil
      expect { status = described_class.call(["--nope"], root: Dir.pwd, out: StringIO.new) }
        .to output(/unrecognized argument: "--nope"/).to_stderr
      expect(status).to eq(64)
    end
  end

  describe Hecks::CLI::SeedSemanticsCorpus do
    it "seeds nothing when every fixture already carries its expect", :aggregate_failures do
      out = StringIO.new

      expect(described_class.call(root: InMemoryDomain::ROOT, env: {}, out: out)).to eq(0)
      expect(out.string).to start_with("nothing to seed")
    end
  end
end

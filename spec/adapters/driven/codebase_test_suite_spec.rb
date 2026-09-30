require "spec_helper"
require "json"
require "hecks/hecks/adapters/codebase/source_tree"
require "hecks/cli/pattern_cases"
require "hecks/cli/refresh_rspec_runtime_baseline"
require "hecks/cli/rspec_io_parallel_files"
require "hecks/cli/rspec_shard_files"
require "hecks/cli/seed_semantics_corpus"
require "hecks/cli/stress_concurrency_specs"
require_relative "../../support/fake_codebase_shell"

RSpec.describe Hecks::Adapters::Codebase::TestSuite do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def word(value) = { value: value }

  def suite(operation, held, shell)
    described_class.call(operation, held, tree, shell: shell)
  end

  def query(operation, args, shell)
    described_class.report(operation, args, tree, shell: shell)
  end

  # The tooling runs in this process: a stand-in for one command answers a status and prints
  # what the real one would, and records the arguments it was called with.
  def command_double(mod, status: 0, prints: "", data: "")
    calls = []
    allow(mod).to receive(:call) do |*args, **options|
      calls << [args, options]
      options[:out]&.print(data)
      warn prints unless prints.empty?
      status
    end
    calls
  end

  describe "the listings" do
    it "asks for one group of the split, with the runtime log when there is one" do
      calls = command_double(Hecks::CLI::RspecShardFiles, data: "spec/a_spec.rb\nspec/b_spec.rb\n")

      files = query("shard_specs", { group: 2, groups: 4, runtime_log: ".github/log" }, nil)

      expect(files).to eq("spec/a_spec.rb\nspec/b_spec.rb")
      expect(calls.first.first).to eq([%w[2 4 .github/log]])
      expect(calls.first.last).to include(root: tree.root)
    end

    it "keeps a command's progress out of the listing" do
      command_double(Hecks::CLI::RspecShardFiles, data: "spec/a_spec.rb\n", prints: "group 1/2 has 1 of 2 files")

      expect(query("shard_specs", { group: 1, groups: 2 }, nil)).to eq("spec/a_spec.rb")
    end

    it "lists the io specs by the postgres job's filter unless tags are named" do
      calls = command_double(Hecks::CLI::RspecIoParallelFiles, data: "spec/db_spec.rb\n")

      query("list_io_parallel_specs", { exclude: "^spec/qa" }, nil)

      expect(calls.first.first).to eq([["^spec/qa", "--", "--tag", "io", "--tag", "~fuzzing"]])
    end

    it "checks a committed list with --check, and a stale list is a refusal" do
      calls = command_double(Hecks::CLI::RspecIoParallelFiles, status: 1, prints: "list.txt is out of date.")

      expect { query("list_io_parallel_specs", { exclude: "x", tags: "--tag slow", check: "list.txt" }, nil) }
        .to raise_error(failure, /out of date/)
      expect(calls.first.first).to eq([["--check", "list.txt", "x", "--", "--tag", "slow"]])
    end

    it "reads the pattern cases with the real command, and they are JSON" do
      cases = JSON.parse(query("record_pattern_cases", {}, nil))

      expect(cases.first.keys).to eq(%w[pattern input matches])
    end
  end

  describe "the baseline" do
    it "reports what it would rewrite and runs nothing unless confirmed" do
      calls = command_double(Hecks::CLI::RefreshRspecRuntimeBaseline)

      report = suite("refresh_runtime_baseline", { from_run: word("42") }, nil)

      expect(report).to start_with("dry run, would read CI run 42's timings and rewrite .github/")
      expect(calls).to be_empty
    end

    it "reads one CI run's timings when confirmed with a run" do
      calls = command_double(Hecks::CLI::RefreshRspecRuntimeBaseline)

      suite("refresh_runtime_baseline", { from_run: word("42"), confirm: word(true) }, nil)

      expect(calls.first.first).to eq([["--from-run", "42"]])
      expect(calls.first.last).to include(root: tree.root)
    end

    it "times a local run with the workers named, when confirmed" do
      calls = command_double(Hecks::CLI::RefreshRspecRuntimeBaseline)

      suite("refresh_runtime_baseline", { workers: word(3), confirm: word(true) }, nil)

      expect(calls.first.first).to eq([["3"]])
    end
  end

  describe "a stress run" do
    it "passes only the counts that were named" do
      calls = command_double(Hecks::CLI::StressConcurrencySpecs)

      suite("stress_concurrency", { runs: word(5), seed_start: word(9) }, nil)

      expect(calls.first.first).to eq([%w[--runs 5 --seed-start 9]])
    end

    it "refuses with the failing runs when a seed fails" do
      command_double(Hecks::CLI::StressConcurrencySpecs, status: 1, prints: "FOUND FLAKINESS - 1/5 runs failed")

      expect { suite("stress_concurrency", {}, nil) }.to raise_error(failure, /FOUND FLAKINESS/)
    end
  end

  describe "the semantics corpus" do
    it "fills the fixtures that lack an expectation" do
      calls = command_double(Hecks::CLI::SeedSemanticsCorpus)

      suite("seed_semantics_corpus", {}, nil)

      expect(calls.first.last[:env]).not_to have_key("SEED")
    end

    it "re-seeds one fixture when it is named" do
      calls = command_double(Hecks::CLI::SeedSemanticsCorpus)

      suite("seed_semantics_corpus", { fixture: word("refusal_kind_lifecycle") }, nil)

      expect(calls.first.last[:env]).to include("SEED" => "refusal_kind_lifecycle")
    end
  end

  describe "the committed spec list" do
    let(:held) { { exclude: word("^spec/qa"), write: word("list.txt") } }

    it "counts the files it would write, and writes none, unless confirmed" do
      calls = command_double(Hecks::CLI::RspecIoParallelFiles, data: "spec/a_spec.rb\nspec/b_spec.rb\n")

      expect(suite("write_io_parallel_spec_list", held, nil))
        .to eq("dry run, would write 2 spec files to list.txt (add --confirm)")
      expect(calls.first.first.first).not_to include("--write")
    end

    it "writes it with --write when confirmed" do
      calls = command_double(Hecks::CLI::RspecIoParallelFiles)

      expect(suite("write_io_parallel_spec_list", held.merge(confirm: word(true)), nil)).to eq("wrote list.txt")
      expect(calls.first.first).to eq([["--write", "list.txt", "^spec/qa", "--", "--tag", "io", "--tag", "~fuzzing"]])
    end
  end

  describe "a single example" do
    it "goes to the test runner in this process" do
      runner = instance_double(Hecks::Adapters::Codebase::TestRunner, run: "1 example, 0 failures")
      allow(Hecks::Adapters::Codebase::TestRunner).to receive(:new).with(tree).and_return(runner)

      report = suite("run_spec_example", { file: word("spec/a_spec.rb"), example: word("works") }, nil)

      expect(report).to eq("1 example, 0 failures")
    end
  end

  describe "the persistence fixtures" do
    it "goes to the SqliteFixture adapter" do
      shell = FakeCodebaseShell.new("sqlite3 3.40\n")

      expect(suite("regenerate_legacy_fixtures", {}, shell)).to include("dry run, would rewrite")
    end
  end
end

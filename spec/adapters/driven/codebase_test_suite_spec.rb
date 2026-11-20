require "spec_helper"
require "json"
require "hecks/hecks/adapters/codebase/source_tree"
require_relative "../../support/fake_codebase_shell"

RSpec.describe Hecks::Adapters::Codebase::TestSuite do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:modules) { described_class }

  def word(value) = { value: value }

  def suite(operation, held, shell)
    described_class.call(operation, held, tree, shell: shell)
  end

  def query(operation, args, shell)
    described_class.report(operation, args, tree, shell: shell)
  end

  describe "the listings" do
    it "asks for one group of the split, with the runtime log when there is one", :aggregate_failures do
      allow(modules::SpecShards).to receive(:files).and_return(%w[spec/a_spec.rb spec/b_spec.rb])

      expect(query("shard_specs", { group: 2, groups: 4, runtime_log: ".github/log" }, nil))
        .to eq("spec/a_spec.rb\nspec/b_spec.rb")
      expect(modules::SpecShards).to have_received(:files)
        .with(root: tree.root, group: 2, groups: 4, runtime_log: ".github/log")
    end

    it "lists the io specs by the postgres job's filter unless tags are named" do
      allow(modules::IoParallelSpecs).to receive(:files).and_return(["spec/db_spec.rb"])
      query("list_io_parallel_specs", { exclude: "^spec/qa" }, nil)

      expect(modules::IoParallelSpecs).to have_received(:files)
        .with(have_attributes(exclude: "^spec/qa", tags: %w[--tag io --tag ~fuzzing]))
    end

    it "checks a committed list, and a stale list is a refusal" do
      allow(modules::IoParallelSpecs).to receive(:files).and_return(["spec/new_spec.rb"])

      expect { query("list_io_parallel_specs", { exclude: "x", check: "absent-list.txt" }, nil) }
        .to raise_error(failure, /absent-list.txt is out of date/)
    end

    it "reads the pattern cases, and they are JSON" do
      cases = JSON.parse(query("record_pattern_cases", {}, nil))

      expect(cases.first.keys).to eq(%w[pattern input matches])
    end
  end

  describe "a stress run" do
    it "passes the counts that were named" do
      allow(modules::StressRun).to receive(:call).and_return("CLEAN")
      suite("stress_concurrency", { runs: word(5), seed_start: word(9) }, nil)

      expect(modules::StressRun).to have_received(:call).with(root: tree.root, runs: 5, seed_start: 9)
    end

    it "refuses a run with no run count or first seed" do
      expect { suite("stress_concurrency", {}, nil) }.to raise_error(failure, /needs runs and seed_start/)
    end
  end

  describe "the semantics corpus" do
    before do
      require "hecks/hecks/adapters/codebase/test_suite/semantics_seeding"
      allow(modules::SemanticsSeeding).to receive(:call).and_return("nothing to seed")
    end

    it "fills the fixtures that lack an expectation" do
      suite("seed_semantics_corpus", {}, nil)

      expect(modules::SemanticsSeeding).to have_received(:call).with(root: tree.root, only: nil)
    end

    it "re-seeds one fixture when it is named" do
      suite("seed_semantics_corpus", { fixture: word("refusal_kind_lifecycle") }, nil)

      expect(modules::SemanticsSeeding).to have_received(:call).with(root: tree.root, only: "refusal_kind_lifecycle")
    end
  end

  describe "the frozen IR golden" do
    it "says what it would rewrite, and runs nothing, unless confirmed" do
      expect(suite("rewrite_ir_golden", {}, nil))
        .to eq("dry run, would rewrite spec/golden/ir from spec/ir_golden_spec.rb (add --confirm)")
    end

    it "runs the golden spec with GOLDEN=rewrite when confirmed" do
      runner = instance_double(Hecks::Adapters::Codebase::TestRunner, run_paths: "1 example, 0 failures")
      allow(Hecks::Adapters::Codebase::TestRunner).to receive(:new).and_return(runner)

      suite("rewrite_ir_golden", { confirm: true }, nil)

      expect(runner).to have_received(:run_paths)
        .with(paths: ["spec/ir_golden_spec.rb"], env: { "GOLDEN" => "rewrite" }, tags: nil)
    end
  end

  describe "the committed spec list" do
    let(:held) { { exclude: word("^spec/qa"), write: word("list.txt") } }

    it "counts the files it would write, and writes none, unless confirmed", :aggregate_failures do
      allow(modules::IoParallelSpecs).to receive_messages(files: %w[spec/a_spec.rb spec/b_spec.rb], write: [])

      expect(suite("write_io_parallel_spec_list", held, nil))
        .to eq("dry run, would write 2 spec files to list.txt (add --confirm)")
      expect(modules::IoParallelSpecs).not_to have_received(:write)
    end

    it "writes it when confirmed" do
      allow(modules::IoParallelSpecs).to receive(:write).and_return([])
      suite("write_io_parallel_spec_list", held.merge(confirm: word(true)), nil)

      expect(modules::IoParallelSpecs).to have_received(:write).with(have_attributes(exclude: "^spec/qa"), "list.txt")
    end
  end

  describe "a single example" do
    it "goes to the test runner in this process" do
      runner = instance_double(Hecks::Adapters::Codebase::TestRunner, run: "1 example, 0 failures")
      allow(Hecks::Adapters::Codebase::TestRunner).to receive(:new).with(tree).and_return(runner)

      report = suite("run_spec_example", { file: word("spec/a_spec.rb"), example: word("works") }, nil)

      expect(report).to eq("1 example, 0 failures")
    end

    def stub_runner
      runner = instance_double(Hecks::Adapters::Codebase::TestRunner, run: "ok")
      allow(Hecks::Adapters::Codebase::TestRunner).to receive(:new).with(tree).and_return(runner)
      runner
    end

    def run_example(extra = {})
      suite("run_spec_example", { file: word("spec/a_spec.rb"), example: word("works") }.merge(extra), nil)
    end

    def named_env = { "CI" => "true", "PROPERTY_SEEDS" => "20", "HECKS_ENVIRONMENT" => "memory" }

    it "hands the specs the variables the run names" do
      runner = stub_runner
      run_example(strict: word(true), seeds: word(20), environment: word("memory"))

      expect(runner).to have_received(:run).with(file: "spec/a_spec.rb", example: "works", env: named_env, tags: nil)
    end

    it "turns the shared declaration cache off for the run when asked", :aggregate_failures do
      runner = stub_runner
      run_example(declaration_cache: word(false), tags: word("--tag cloudfront"))

      expect(runner).to have_received(:run).with(file: "spec/a_spec.rb", example: "works", tags: "--tag cloudfront",
                                                 env: { "HECKS_NO_DECLARATION_CACHE" => "1" })
    end

    it "hands the specs no variables when the run names none" do
      runner = stub_runner
      run_example

      expect(runner).to have_received(:run).with(file: "spec/a_spec.rb", example: "works", env: {}, tags: nil)
    end

    # Installs a runner that records `PROPERTY_SEEDS` as the run sees it.
    def install_runner
      seen = []
      Hecks::Adapters::Codebase::TestRunner.runner = lambda do |_args, out, _err|
        seen << ENV.fetch("PROPERTY_SEEDS", nil)
        out.puts "1 example, 0 failures"
        0
      end
      seen
    end

    def seeds_during_run(env)
      seen = install_runner
      Hecks::Adapters::Codebase::TestRunner.new(tree).run(file: "spec/spec_helper.rb", example: "x", env: env)
      [seen.first, ENV.fetch("PROPERTY_SEEDS", nil)]
    ensure
      Hecks::Adapters::Codebase::TestRunner.runner = nil
    end

    it "sets the variables for the run only, and puts them back" do
      expect(seeds_during_run("PROPERTY_SEEDS" => "7")).to eq(["7", nil])
    end

    # The arguments the runner was handed for one run.
    def runner_arguments(**options)
      given = nil
      Hecks::Adapters::Codebase::TestRunner.runner = lambda do |args, out, _err|
        given = args
        out.puts "1 example, 0 failures"
        0
      end
      Hecks::Adapters::Codebase::TestRunner.new(tree).run(file: "spec/spec_helper.rb", example: "x", **options)
      given
    ensure
      Hecks::Adapters::Codebase::TestRunner.runner = nil
    end

    it "hands the runner the tag filters, a word each, before the file" do
      expect(runner_arguments(tags: "--tag cloudfront").first(4)).to eq(["--example", "x", "--tag", "cloudfront"])
    end
  end

  describe "the persistence fixtures" do
    it "goes to the SqliteFixture adapter" do
      shell = FakeCodebaseShell.new("sqlite3 3.40\n")

      expect(suite("regenerate_legacy_fixtures", {}, shell)).to include("dry run, would rewrite")
    end
  end
end

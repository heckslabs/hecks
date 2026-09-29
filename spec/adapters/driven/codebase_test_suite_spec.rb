require "spec_helper"
require "json"
require "hecks/hecks/adapters/codebase/source_tree"
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

  describe "the listings" do
    it "asks for one group of the split, with the runtime log when there is one" do
      shell = FakeCodebaseShell.new("spec/a_spec.rb\nspec/b_spec.rb\n")

      files = query("shard_specs", { group: 2, groups: 4, runtime_log: ".github/log" }, shell)

      expect(files).to eq("spec/a_spec.rb\nspec/b_spec.rb")
      expect(shell.command).to eq([tree.path("bin/rspec_shard_files"), "2", "4", ".github/log"])
      expect(shell.env).to include("HECKS_NO_3_0_NOTICE" => "1")
    end

    it "lists the io specs by the postgres job's filter unless tags are named" do
      shell = FakeCodebaseShell.new("spec/db_spec.rb\n")

      query("list_io_parallel_specs", { exclude: "^spec/qa" }, shell)

      expect(shell.command).to eq([tree.path("bin/rspec_io_parallel_files"), "^spec/qa", "--",
                                   "--tag", "io", "--tag", "~fuzzing"])
    end

    it "checks a committed list with --check, and a stale list is a refusal" do
      shell = FakeCodebaseShell.new(["list.txt is out of date.\n", 1])

      expect { query("list_io_parallel_specs", { exclude: "x", tags: "--tag slow", check: "list.txt" }, shell) }
        .to raise_error(failure, /out of date/)
      expect(shell.command).to eq([tree.path("bin/rspec_io_parallel_files"), "--check", "list.txt", "x", "--",
                                   "--tag", "slow"])
    end

    it "reads the pattern cases with the real script, and they are JSON" do
      cases = JSON.parse(query("record_pattern_cases", {}, nil))

      expect(cases.first.keys).to eq(%w[pattern input matches])
    end
  end

  describe "the baseline" do
    it "reports what it would rewrite and runs nothing unless confirmed" do
      shell = FakeCodebaseShell.new

      report = suite("refresh_runtime_baseline", { from_run: word("42") }, shell)

      expect(report).to start_with("dry run, would read CI run 42's timings and rewrite .github/")
      expect(shell.asked).to be_empty
    end

    it "reads one CI run's timings when confirmed with a run" do
      shell = FakeCodebaseShell.new("wrote .github/rspec_runtime_baseline.log: 10 spec files\n")

      suite("refresh_runtime_baseline", { from_run: word("42"), confirm: word(true) }, shell)

      expect(shell.command).to eq([tree.path("bin/refresh_rspec_runtime_baseline"), "--from-run", "42"])
    end

    it "times a local run with the workers named, when confirmed" do
      shell = FakeCodebaseShell.new

      suite("refresh_runtime_baseline", { workers: word(3), confirm: word(true) }, shell)

      expect(shell.command).to eq([tree.path("bin/refresh_rspec_runtime_baseline"), "3"])
    end
  end

  describe "a stress run" do
    it "passes only the counts that were named" do
      shell = FakeCodebaseShell.new("CLEAN - 5/5 runs passed.\n")

      suite("stress_concurrency", { runs: word(5), seed_start: word(9) }, shell)

      expect(shell.command).to eq([tree.path("bin/stress_concurrency_specs"), "--runs", "5", "--seed-start", "9"])
    end

    it "refuses with the failing runs when a seed fails" do
      shell = FakeCodebaseShell.new(["FOUND FLAKINESS - 1/5 runs failed\n", 1])

      expect { suite("stress_concurrency", {}, shell) }.to raise_error(failure, /FOUND FLAKINESS/)
    end
  end

  describe "the semantics corpus" do
    it "fills the fixtures that lack an expectation" do
      shell = FakeCodebaseShell.new("nothing to seed\n")

      suite("seed_semantics_corpus", {}, shell)

      expect(shell.env).not_to have_key("SEED")
    end

    it "re-seeds one fixture when it is named" do
      shell = FakeCodebaseShell.new("seeded: refusal_kind_lifecycle\n")

      suite("seed_semantics_corpus", { fixture: word("refusal_kind_lifecycle") }, shell)

      expect(shell.env).to include("SEED" => "refusal_kind_lifecycle")
    end
  end

  describe "the committed spec list" do
    let(:held) { { exclude: word("^spec/qa"), write: word("list.txt") } }

    it "counts the files it would write, and writes none, unless confirmed" do
      shell = FakeCodebaseShell.new("spec/a_spec.rb\nspec/b_spec.rb\n")

      expect(suite("write_io_parallel_spec_list", held, shell))
        .to eq("dry run, would write 2 spec files to list.txt (add --confirm)")
      expect(shell.command).not_to include("--write")
    end

    it "writes it with --write when confirmed" do
      shell = FakeCodebaseShell.new

      expect(suite("write_io_parallel_spec_list", held.merge(confirm: word(true)), shell)).to eq("wrote list.txt")
      expect(shell.command).to eq([tree.path("bin/rspec_io_parallel_files"), "--write", "list.txt", "^spec/qa", "--",
                                   "--tag", "io", "--tag", "~fuzzing"])
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

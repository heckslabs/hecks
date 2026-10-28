require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/ci_speed/adapters/local_runner"

# The `LocalRunner` adapter of the CiSpeed chapter runs an experiment's steps in two temporary
# checkouts of the refs it names. This spec gives it a tiny definition whose steps ask the launcher
# for usage, so nothing is regenerated, and two commits of this repository: its newest and one on
# top of it with the same tree, made in the spec's own clone, because CI checks out one commit and
# has no `HEAD~1` to name. The repository the adapter asks is a shared clone made for the spec, so
# what the adapter does to "the caller's checkout" can be read off exactly while other work goes on
# in the working tree this spec runs from.
RSpec.describe Hecks::Adapters::LocalRunner do
  let(:catalog_class) { described_class::Catalog }

  before do
    git(Dir.pwd, "clone", "--shared", "--no-checkout", "--quiet", Dir.pwd, caller_checkout)
    commit_the_same_tree_again(caller_checkout)
  end

  after { FileUtils.remove_entry(scratch) }

  def scratch = @scratch ||= Dir.mktmpdir("ci-speed-runner-spec-")

  def caller_checkout = File.join(scratch, "caller")

  def git(directory, *words)
    out, status = Open3.capture2e("git", "-C", directory, *words)
    raise "git #{words.join(" ")} failed: #{out}" unless status.success?

    out
  end

  # Moves `HEAD` to a new commit with its tree, so `HEAD~1` names a commit however deep the clone
  # is. A commit made from the index would be empty: the clone is made without a checkout.
  def commit_the_same_tree_again(directory)
    author = ["-c", "user.name=ci speed spec", "-c", "user.email=ci-speed-spec@example.test"]
    made = git(directory, *author, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "the same tree again").strip
    git(directory, "update-ref", "HEAD", made)
  end

  def step(name, verb, needs: "none", arguments: "--help")
    catalog_class::Step.new(name: name, verb: verb, arguments: arguments, needs: needs)
  end

  def definition(*steps, needs_generated_tree: "no")
    catalog_class.new([catalog_class::Definition.new(name: "tiny", measures: "the launcher's usage",
                                                     cache_state: "miss", steps: steps,
                                                     needs_generated_tree: needs_generated_tree)])
  end

  def runner_for(catalog)
    described_class.new(catalog: catalog, root: caller_checkout, scratch: File.join(scratch, "runs"))
  end

  def usage_runner = runner_for(definition(step("usage", "Checkout.status")))

  def experiment(**changes)
    { measures: { value: "tiny" }, cache_state: { value: "miss" }, base_ref: { value: "HEAD~1" },
      candidate_ref: { value: "HEAD" }, repeats: { value: 2 } }.merge(changes)
  end

  def standing(directory)
    { head: git(directory, "rev-parse", "HEAD"), status: git(directory, "status", "--porcelain"),
      worktrees: git(directory, "worktree", "list", "--porcelain") }
  end

  def checkouts_of(runner) = runner.trail.map { |taken| taken[:checkout] }.uniq

  def steps_this_machine_cannot_run
    [step("load_database", "Checkout.status", needs: "postgres"), step("no_such_verb", "NoSuchAggregate.nothing!")]
  end

  def unmeasured_of(*steps)
    runner_for(definition(*steps)).measure(**experiment).fetch(:unmeasured).fetch(:value)
  end

  describe "#measure" do
    it "answers with the numbers, in the shape Experiment::Complete takes", :aggregate_failures do
      answer = usage_runner.measure(**experiment)

      expect(answer.keys).to contain_exactly(:base_seconds, :candidate_seconds, :spread_seconds, :saved_seconds,
                                             :load, :unmeasured, :verdict, :basis, :reestimates, :expected_seconds)
      expect(answer.fetch(:verdict).fetch(:value)).to match(/\A(faster|slower|inconclusive)\z/)
      expect(answer.fetch(:base_seconds).fetch(:value)).to be_positive
    end

    it "leaves the caller's checkout, its status and its worktree list as they were" do
      before_run = standing(caller_checkout)

      usage_runner.measure(**experiment)

      expect(standing(caller_checkout)).to eq(before_run)
    end

    it "removes both worktrees afterwards", :aggregate_failures do
      runner = usage_runner

      runner.measure(**experiment)

      expect(checkouts_of(runner).size).to eq(2)
      expect(checkouts_of(runner)).to all(satisfy { |path| !File.exist?(path) })
      expect(git(caller_checkout, "worktree", "list")).not_to include("ci-experiment-")
    end

    it "removes both worktrees when a step ends badly", :aggregate_failures do
      refused_domain = step("fails", "RegenerationRun.regenerate_corpus!", arguments: "domains.value=NOT_A_DOMAIN")
      before_run = standing(caller_checkout)

      expect { runner_for(definition(refused_domain)).measure(**experiment) }
        .to raise_error(described_class::Refused, /fails/)
      expect(standing(caller_checkout)).to eq(before_run)
    end

    it "samples the two sides interleaved, base first in every round" do
      runner = usage_runner

      runner.measure(**experiment(repeats: { value: 3 }))

      expect(runner.trail.map { |taken| [taken[:round], taken[:side]] })
        .to eq([[0, :base], [0, :candidate], [1, :base], [1, :candidate], [2, :base], [2, :candidate]])
    end

    it "runs each side once untimed before sampling, and keeps that pass out of the samples", :aggregate_failures do
      runner = usage_runner

      runner.measure(**experiment(repeats: { value: 2 }))

      expect(runner.warm_up.map { |pass| pass[:side] }).to eq(%i[base candidate])
      expect(runner.trail.map { |taken| taken[:round] }).to eq([0, 0, 1, 1])
    end

    it "names a step it cannot stand in for in unmeasured, and times neither side with it", :aggregate_failures do
      unmeasured = unmeasured_of(step("usage", "Checkout.status"), *steps_this_machine_cannot_run)

      expect(unmeasured).to include("load_database: needs postgres")
      expect(unmeasured).to include("no_such_verb: NoSuchAggregate.nothing! or an argument it is given is unknown")
      expect(unmeasured).not_to include("usage:")
    end

    it "names a step whose argument a ref does not know, as unmeasured" do
      unmeasured = unmeasured_of(step("usage", "Checkout.status"),
                                 step("new_argument", "Checkout.status", arguments: "no_such.value=1"))

      expect(unmeasured).to include("new_argument: Checkout.status or an argument it is given is unknown")
    end

    it "refuses an experiment none of whose steps can be measured" do
      runner = runner_for(definition(step("load_database", "Checkout.status", needs: "postgres")))

      expect { runner.measure(**experiment) }
        .to raise_error(described_class::Refused, /no step could be measured here: load_database/)
    end

    it "refuses a definition that is not defined, listing those that are" do
      expect { usage_runner.measure(**experiment(measures: { value: "other" })) }
        .to raise_error(described_class::Refused, /no experiment definition is named "other"; defined: tiny/)
    end

    it "refuses a definition that stands for another cache state" do
      expect { usage_runner.measure(**experiment(cache_state: { value: "hit" })) }
        .to raise_error(described_class::Refused, /tiny measures cache state miss, but the experiment stands for hit/)
    end

    it "refuses refs that are the same commit" do
      expect { usage_runner.measure(**experiment(base_ref: { value: "HEAD" })) }
        .to raise_error(described_class::Refused, /are the same commit/)
    end

    it "refuses a ref that names no commit" do
      expect { usage_runner.measure(**experiment(base_ref: { value: "no_such_ref" })) }
        .to raise_error(described_class::Refused, /names no commit/)
    end

    it "refuses a generated tree it was asked to copy when the caller holds none" do
      runner = runner_for(definition(step("usage", "Checkout.status"), needs_generated_tree: "yes"))

      expect { runner.measure(**experiment) }.to raise_error(described_class::Refused, /holds none/)
    end
  end

  describe described_class::Checkouts, ".reset_generated_tree" do
    def tree = described_class::GENERATED_TREE

    def source = File.join(scratch, "source")

    def checkout = File.join(scratch, "checkout")

    before do
      FileUtils.mkdir_p(File.join(source, tree))
      File.write(File.join(source, tree, "banking.rs"), "pub fn banking() {}")
      FileUtils.mkdir_p(File.join(checkout, tree))
      File.write(File.join(checkout, tree, "left_over.rs"), "stale")
    end

    it "empties the tree of a sample that starts cold" do
      described_class.reset_generated_tree(checkout, nil)

      expect(File.exist?(File.join(checkout, tree))).to be(false)
    end

    it "replaces the tree with a copy of the caller's", :aggregate_failures do
      described_class.reset_generated_tree(checkout, source)

      expect(Dir.children(File.join(checkout, tree))).to eq(["banking.rs"])
      expect(Dir.children(File.join(source, tree))).to eq(["banking.rs"])
    end
  end

  describe described_class::LoadAverage, ".now" do
    it "is the machine's one-minute load average" do
      expect(described_class.now).to be >= 0.0
    end
  end

  describe described_class::Verdict do
    def verdict(base, candidate) = described_class.new(base: base, candidate: candidate)

    it "calls a saving larger than the spread faster, and tells the lever its whole seconds", :aggregate_failures do
      result = verdict([40.0, 41.0, 42.0], [30.0, 31.0, 32.0])

      expect(result.verdict).to eq("faster")
      expect(result.saved_seconds).to eq(10.0)
      expect(result.spread_seconds).to eq(2.0)
      expect(result.expected_seconds).to eq(10)
    end

    it "calls a saving within the spread inconclusive, and tells the lever nothing", :aggregate_failures do
      result = verdict([40.0, 46.0, 43.0], [41.0, 44.0, 42.0])

      expect(result.verdict).to eq("inconclusive")
      expect(result.expected_seconds).to eq(0)
    end

    it "calls a loss larger than the spread slower, and tells the lever nothing", :aggregate_failures do
      result = verdict([30.0, 31.0], [40.0, 41.0])

      expect(result.verdict).to eq("slower")
      expect(result.saved_seconds).to eq(-10.0)
      expect(result.expected_seconds).to eq(0)
    end

    it "takes the spread from the side that varied more" do
      expect(verdict([10.0, 10.1], [20.0, 25.0]).spread_seconds).to eq(5.0)
    end
  end
end

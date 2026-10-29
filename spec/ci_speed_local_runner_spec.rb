require "spec_helper"
require_relative "support/local_runner_world"

# The `LocalRunner` adapter of the CiSpeed chapter runs an experiment's steps in two temporary
# checkouts of the refs it names. This spec holds what it does to those checkouts and to the one it
# was asked about, and its refusals; the sampling examples are in
# ci_speed_local_runner_sampling_spec.rb, and the setup both share is in
# support/local_runner_world.rb.
RSpec.describe Hecks::Adapters::LocalRunner do
  include_context "with a local runner over a shared clone"

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

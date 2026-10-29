require "spec_helper"
require_relative "support/local_runner_world"

# The sampling half of the `LocalRunner` specs: the order the two sides are timed in, the untimed
# pass before sampling, and the steps a ref cannot run. Each example runs the launcher in two real
# checkouts, so these are the costly ones, kept in a file of their own beside the worktree specs of
# ci_speed_local_runner_spec.rb so the two can run in different shards.
RSpec.describe Hecks::Adapters::LocalRunner, "#measure" do
  include_context "with a local runner over a shared clone"

  describe "sampling and the steps a ref cannot run" do
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
  end
end

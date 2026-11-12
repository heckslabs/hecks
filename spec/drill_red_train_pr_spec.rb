# frozen_string_literal: true

require "spec_helper"
require_relative "support/red_drill"

# The red drill: a spec that fails on purpose so a real train pull request goes red and the red
# path (TrainPrFailed, a rerun, a red-train work item, the pull request closed) is seen on a real
# failure. The example is defined only while {RedDrill.on?}; with the switch off the file defines
# nothing, so CI sees no skipped example and no failure.
if RedDrill.on?
  RSpec.describe "the red drill" do
    it "fails on purpose so a train pull request goes red" do
      expect(false).to be(true), "red drill, on: this failure is deliberate (spec/drill_red_train_pr_spec.rb)"
    end
  end
end

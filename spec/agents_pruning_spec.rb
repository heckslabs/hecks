require "spec_helper"
require_relative "support/resting_pruner"

# A landed feature starts the reap of finished sessions, which wakes no pruner agent; a run that
# finishes without landing starts nothing.
RSpec.describe "the reap started by a landed feature" do
  include_context "with a resting pruner"

  it "dispatches no pruner when a coder run finishes" do
    dispatch("w-finished")
    finish("w-finished")
    expect(pruners_started).to eq(0)
  end

  it "reaps the finished sessions for the landing and wakes no pruner", :aggregate_failures do
    land("w-own")
    expect(reactions("ReapWhenWorkLands").size).to eq(1)
    expect(pruners_started).to eq(0)
  end
end

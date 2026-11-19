require "spec_helper"
require "hecks/hecks/adapters/reviewer_judgment"

# The reviewer's judgment is the last judgment word its report names: the report ends with it.
RSpec.describe Hecks::Adapters::ReviewerJudgment do
  it "reads landed, which ends a review whose branch landed before it ran" do
    expect(described_class.of("The branch is on main.\n\nlanded")).to eq("landed")
  end

  it "takes the last word named, not one named in passing" do
    expect(described_class.of("Before it landed, one spec failed: a real bug.\n\nstale_expectation")).to eq("stale_expectation")
  end

  it "reads nothing from a report that names no judgment" do
    expect(described_class.of("no specs ran")).to eq("")
  end
end

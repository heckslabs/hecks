require "spec_helper"
require "hecks/hecks/adapters/reviewer_judgment"

# The reviewer's judgment is its closing line: one word alone on the last line that says something.
RSpec.describe Hecks::Adapters::ReviewerJudgment do
  it "reads landed, which ends a review whose branch landed before it ran" do
    expect(described_class.of("The branch is on main.\n\nlanded")).to eq("landed")
  end

  it "reads a closing word in backticks, with a trailing period" do
    expect(described_class.of("Every cited run passed.\n`missing_behavior`.\n")).to eq("missing_behavior")
  end

  it "reads clean only from the closing line, not from a finding that says it in passing" do
    expect(described_class.of("model_check is clean\nI could not run the behaviors.")).to eq("")
  end

  it "takes the closing line over a word named before it" do
    expect(described_class.of("Before it landed, one spec failed: a real bug.\n\nstale_expectation")).to eq("stale_expectation")
  end

  it "reads nothing from a report whose last line is prose" do
    expect(described_class.of("One failure is a stale expectation.")).to eq("")
  end

  it "lists the words the SubmissionReview.Judge given accepts" do
    expect(described_class::WORDS).to eq(%w[clean real_bug stale_expectation missing_behavior landed])
  end
end

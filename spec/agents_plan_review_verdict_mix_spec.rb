require "spec_helper"
require_relative "support/plan_review_limit_helpers"
require_relative "support/verdict_mix_helpers"

# The mix of the architect's verdicts, which the `VerdictMix` read model counts, and the rubric
# section that says when each verdict is given.
RSpec.describe "the Agents plan review verdict mix" do
  include PlanReviewLimitHelpers
  include VerdictMixHelpers

  let(:registry) { Hecks::Runtime::Registry.new }

  it "counts the reviews that ended in each verdict" do
    boot_into(registry)
    %w[changes changes sound].each_with_index { |word, index| answer_with("r#{index}", word) }
    expect(mix).to eq("changes" => 2, "sound" => 1)
  end

  it "keeps the rubric's verdict section: notes ride along with a sound plan", :aggregate_failures do
    rubric = File.read(File.join(InMemoryDomain::ROOT, "docs/ARCHITECTURE_REVIEW.md"))
    expect(rubric).to include("## V. Verdict")
    expect(rubric).to include("Notes ride along under a `Notes` heading")
  end
end

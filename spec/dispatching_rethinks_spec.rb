require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# What the architect's rethinks say to the next coder: the findings reach the brief once each, and
# the third rethink holds the work item. The reviews are stand-in PlanReview rows.
RSpec.describe Hecks::Adapters::Dispatching::Rethinks do
  def review(run, verdict, work: "w1") = { run: run, work: work, verdict: verdict, findings: "findings of #{run}" }

  def rethinks(*reviews) = described_class.new(reviews)

  def three = Array.new(3) { |index| review("w1-#{index}", "rethink") }

  let(:mixed) { rethinks(review("r1", "rethink"), review("r2", "changes"), review("r3", "rethink", work: "w2")) }

  it "writes the rejection first and then each rethink's findings", :aggregate_failures do
    section = mixed.section("w1")

    expect(section).to start_with("A previous plan was rejected: findings below; plan from them.")
    expect(section).to include("Review r1 (rethink):\nfindings of r1")
  end

  it "leaves out a review that did not say rethink and one of another work item", :aggregate_failures do
    expect(mixed.section("w1")).not_to include("r2", "r3")
    expect(mixed.section("none")).to eq("")
  end

  it "names each review's findings once, however often the section is read", :aggregate_failures do
    2.times { expect(mixed.section("w1").scan("findings of r1").size).to eq(1) }
  end

  it "holds a work item at the limit, naming its reviews" do
    expect(rethinks(*three).stop_reason("w1")).to eq("skipped: needs a person: 3 architect rethinks (w1-0, w1-1, w1-2)")
  end

  it "holds nothing below the limit" do
    expect(rethinks(*three.first(2)).stop_reason("w1")).to be_nil
  end

  it "puts the section right after the outcome in the brief text" do
    text = Hecks::Adapters::Dispatching::BriefText.new("outcome" => "x").render("w1", rethinks: mixed.section("w1"))

    expect(text.lines.drop(1).join).to start_with("\nA previous plan was rejected")
  end
end

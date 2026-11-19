require "spec_helper"
require "json"
require "securerandom"

# A landing's wait for the reviewer's verdict on its tip, in a Memory domain: a clean verdict
# clears it, any other verdict refuses an enforced landing and lets a shadowed one land anyway,
# and a verdict for another commit finds no review.
RSpec.describe "a landing waiting for review" do
  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def await(tip, mode: "enforce")
    launch("LandingReview.await!", "tip.value=#{tip}", "run.value=run-#{tip}", "checkout.value=/scratch/#{tip}",
           "branch.value=w-#{tip}", "brief.value=build it", "confirm.value=true", "mode.value=#{mode}", "--wait")
  end

  def judge(tip, verdict) = launch("LandingReview.judge!", "to=#{tip}", "verdict.value=#{verdict}", "--wait")

  def status(tip)
    rows = JSON.parse(launch("LandingReview.landing_reviews").first.to_s)
    rows.find { |row| row["tip"] == tip }&.fetch("status")
  end

  def tip = SecureRandom.hex(4)

  it "records a tip whose gates passed as awaiting review" do
    sha = tip.tap { |t| await(t) }
    expect(status(sha)).to eq("awaiting_review")
  end

  it "clears a landing whose tip the reviewer judged clean" do
    sha = tip.tap { |t| await(t) }
    judge(sha, "clean")
    expect(status(sha)).to eq("cleared")
  end

  it "refuses an enforced landing whose tip was not judged clean" do
    sha = tip.tap { |t| await(t) }
    judge(sha, "real_bug")
    expect(status(sha)).to eq("refused")
  end

  it "lets a shadowed landing land anyway on a verdict other than clean" do
    sha = tip.tap { |t| await(t, mode: "shadow") }
    judge(sha, "stale_expectation")
    expect(status(sha)).to eq("shadowed")
  end

  it "leaves a landing waiting when the verdict names another tip" do
    sha = tip.tap { |t| await(t) }
    judge(tip, "clean")
    expect(status(sha)).to eq("awaiting_review")
  end

  it "refuses a mode other than enforce or shadow" do
    sha = tip.tap { |t| await(t, mode: "sometimes") }
    expect(status(sha)).to be_nil
  end
end

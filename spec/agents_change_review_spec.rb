require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"
require_relative "support/change_review_helpers"

# The architect's review of a submitted change: asked when the branch changed a bluebook, a
# hecksagon or a decision file, or when its paths cannot be read; passed otherwise; cleared when
# sound, and sent back to the coder of the Work item when not.
RSpec.describe "the architect's change review" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include ChangeReviewHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:woken) { [] }

  before { fake_runner(woken) }

  def status(review) = change_review(review)&.fetch("status")

  it "asks the architect about a branch that changed a bluebook" do
    sha = branch_changing("lib/x/x.bluebook", "spec/x_spec.rb").tap { |tip| consider(tip) }
    expect(status(sha)).to eq("asked")
  end

  it "asks the architect about a branch that changed a decision file" do
    sha = branch_changing("docs/decisions/0300-x.md").tap { |tip| consider(tip) }
    expect(status(sha)).to eq("asked")
  end

  it "passes a branch that changed no bluebook, hecksagon or decision file" do
    sha = branch_changing("lib/x/x.rb", "spec/x_bluebook_spec.rb").tap { |tip| consider(tip) }
    expect(status(sha)).to eq("unasked")
  end

  it "passes a change without refusing the request it does not need" do
    sha = branch_changing("lib/x/x.rb")
    expect(consider(sha).last).to eq(Hecks::Adapters::Driving::ExitStatus::ANSWERED)
  end

  it "ends a review whose paths cannot be read as unread, never passed" do
    branch_changing("lib/x/x.rb")
    consider("0" * 40)
    expect(status("0" * 40)).to eq("unread")
  end

  it "starts the architect's run keyed by the commit's tree, with no Work item" do
    sha = branch_changing("lib/x/x.hecksagon").tap { |tip| consider(tip) }
    run = running(git("rev-parse", "#{sha}^{tree}").strip)
    expect(run.slice("agent", "work").transform_values(&:to_s)).to eq("agent" => "architect", "work" => "")
  end

  it "starts the architect's run from a submission, within the reaction depth" do
    sha = branch_changing("lib/x/x.bluebook")
    launch("coder", "Submission.submit!", "branch.value=w-change", "sha.value=#{sha}",
           "checkout.value=#{scratch}", "clean.value=true", "--wait")
    expect(running(git("rev-parse", "#{sha}^{tree}").strip)).not_to be_nil
  end

  it "starts the architect with the commit as its brief, so it names no command it cannot run" do
    sha = branch_changing("lib/x/x.bluebook").tap { |tip| consider(tip) }
    expect(running(git("rev-parse", "#{sha}^{tree}").strip)["brief"].to_s).to eq(sha)
  end

  it "leaves the commit's own key to the reviewer's run" do
    sha = branch_changing("lib/x/x.bluebook").tap { |tip| consider(tip) }
    expect(running(sha)).to be_nil
  end

  it "clears a change the architect judged sound" do
    sha = branch_changing("lib/x/x.bluebook").tap { |tip| consider(tip) }
    architect_closes(sha, "Verdict: sound. Fine as it is.")
    expect(status(sha)).to eq("cleared")
  end

  it "sends a change not judged sound back to its coder, with the findings", :aggregate_failures do
    sha = branch_changing("lib/x/x.bluebook").tap { |tip| consider(tip) }
    architect_closes(sha, "Verdict: sound with changes. Split the aggregate.")
    expect(status(sha)).to eq("sent_back")
    expect(verdict_for(sha).values_at("work", "role")).to eq(%w[w-change architect])
  end

  it "holds a change whose review checked nothing, never clearing it", :aggregate_failures do
    sha = branch_changing("lib/x/x.bluebook").tap { |tip| consider(tip) }
    architect_closes(sha, "Verdict: sound. Nothing was checked: the diff could not be read.")
    expect(status(sha)).to eq("held")
    expect(verdict_for(sha)["answer"]).to include("counts as no review")
  end

  it "sends the architect's findings to the coder as written" do
    sha = branch_changing("lib/x/x.bluebook").tap { |tip| consider(tip) }
    architect_closes(sha, "Verdict: rethink. Split the aggregate.")
    expect(verdict_for(sha)["answer"]).to include("Split the aggregate.")
  end

  it "records no plan review for a change review's verdict" do
    sha = branch_changing("lib/x/x.bluebook").tap { |tip| consider(tip) }
    architect_closes(sha, "Verdict: sound.")
    expect(plan_review(run_of(sha))).to be_nil
  end
end

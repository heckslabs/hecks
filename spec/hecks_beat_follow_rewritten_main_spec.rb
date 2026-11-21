# frozen_string_literal: true

require "spec_helper"
require "support/rewritten_main_copy"
require "hecks/hecks/adapters/main_integration"

# The beat copy after local main is rewritten, as `LinkedTree.pull_main!` rewrites it: the copy's
# head is off main's history, and `Clearance.Grant` refuses a head that is not main's.
RSpec.describe "the beat copy after local main is rewritten" do
  include RewrittenMainCopy

  before { rewrite_main }

  it "is not an ancestor of the rewritten main before the follow" do
    expect { git("merge-base", "--is-ancestor", copy_head, "main") }.to raise_error(/git/)
  end

  it "follows to the rewritten tip, so the clearance given head == main holds" do
    follow
    expect(copy_head).to eq(git("rev-parse", "main"))
  end

  it "leaves a copy with a tracked change where it is and says so in the overrun log", :aggregate_failures do
    File.write(File.join(copy, "first"), "changed")
    stayed = copy_head
    follow
    expect(copy_head).to eq(stayed)
    expect(File.read(log)).to include(Hecks::Adapters::MainIntegration::FollowMain::REFUSAL)
  end

  it "does not count an untracked file as a change" do
    File.write(File.join(copy, "untracked"), "x")
    follow
    expect(copy_head).to eq(git("rev-parse", "main"))
  end
end

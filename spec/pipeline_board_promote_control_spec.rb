# frozen_string_literal: true

require "spec_helper"

# The board offers one by-hand Promote control that moves stable to the newest green commit, and
# lists no recommendation per verified change.
RSpec.describe "the board's Promote control" do
  let(:root) { File.expand_path("../lib/hecks/pipeline_board", __dir__) }
  let(:page) { File.read(File.join(root, "adapters/pipeline_web/page.html")) }
  let(:script) { File.read(File.join(root, "adapters/pipeline_web/answer.js")) }
  let(:bluebook) { File.read(File.join(root, "pipeline_board.bluebook")) }

  it "renders one Promote control that runs the promote action" do
    expect(page.scan('act: "promote"').size).to eq(1)
  end

  it "declares one promote action that moves the stable lane" do
    expect(bluebook.scan('member action: "promote"').size).to eq(1)
  end

  it "runs PromotionRun.promote! on lane stable" do
    expect(bluebook).to include("PromotionRun.promote! lane=stable --confirm --wait")
  end

  it "lists no recommendation and has no Dismiss or settle step" do
    expect([page, script, bluebook].join).not_to match(/PromotionRecommendation|Dismiss|"settle"/i)
  end
end

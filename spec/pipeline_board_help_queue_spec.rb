# frozen_string_literal: true

require "spec_helper"
require_relative "support/help_queue_calls"

# The calls for help the owner is shown on the Waiting-on-you panel: one whose help is the owner's
# at once, any other only once its block has stood past the `help_unanswered_minutes` setting.
RSpec.describe Hecks::Adapters::PipelineBoard::HelpQueue do
  include HelpQueueCalls

  let(:limit) { Hecks::Adapters::PipelineBoard::Rules.setting("help_unanswered_minutes") }

  it "shows a call whose help is the owner's at once" do
    expect(shown(call(role: "owner"))).to eq(["needs you: login for X, 5m"])
  end

  it "keeps a call for another role off the panel while it is under the limit" do
    expect(shown(call(minutes: limit - 1))).to eq([])
  end

  it "shows a call for another role once it has stood for the limit" do
    expect(shown(call(minutes: limit)).size).to eq(1)
  end

  it "never shows another role's call whose opening time cannot be read" do
    expect(shown(call.merge(opened_at: "soon"))).to eq([])
  end
end

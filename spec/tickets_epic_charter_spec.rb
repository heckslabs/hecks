require "spec_helper"
require_relative "support/epic_charter_helpers"

# The owner writes a charter; the product owner ranks from it with a command of its own.
RSpec.describe "the Tickets Epic's charter" do
  include EpicCharterHelpers

  before { epic }

  it "answers the charter's lines in the owner's order" do
    text = JSON.parse(cli("epic.charter")).first.fetch("text")
    expect(text.scan(/^(\d)\. /).flatten).to eq(%w[1 2 3 4])
  end

  it "lets the product owner rank an epic nobody ranked by hand" do
    rerank(4)
    expect(tier_of).to eq(4)
  end

  it "refuses a product owner's tier outside 1 to 9" do
    expect(rerank(10)).to include("an epic tier is from 1 to 9")
  end

  it "lets the owner rank over their own hand rank" do
    rank(2)
    rank(5)
    expect(tier_of).to eq(5)
  end
end

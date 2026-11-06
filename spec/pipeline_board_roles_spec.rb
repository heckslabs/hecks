# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The pinned agents panel: each role's newest event, taken from the board's event feed.
RSpec.describe Hecks::Adapters::PipelineBoard::AgentRoles do
  let(:events) do
    [{ name: "TestSuiteFaulted", at: "t3", id: "x" }, { name: "PlanReviewed", at: "t2", id: "r1" },
     { name: "PlanReviewRequested", at: "t1", id: "r1" }]
  end

  def roles = described_class.of([], %w[architect coder], events)

  it "names the newest event a role handled, with its time", :aggregate_failures do
    expect(roles.first[:last]).to eq(name: "PlanReviewed", at: "t2", id: "r1")
    expect(roles.last[:last]).to be_nil
  end

  it "counts a session toward the role its run names, whatever claude titled it", :aggregate_failures do
    titled = { name: "attestation-waiver lane data", status: "done", agent: "architect", detail: "3 consumers hardcoded" }
    card = described_class.of([titled], %w[architect], events).first
    expect(card[:completed].map { |s| s[:name] }).to eq(["attestation-waiver lane data"])
    expect(card[:live]).to eq(0)
  end

  it "has no last event when the feed could not be read" do
    expect(described_class.of([], %w[architect], { unknown: "x" }).first[:last]).to be_nil
  end
end

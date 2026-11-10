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

  describe "a session whose run records the part it works as" do
    let(:filled) { { name: "fix-a work", status: "busy", agent: "", works_as: "coder", work_item: "fix-a" } }

    def coder(session = filled) = described_class.of([session], %w[coder], events).first

    it "counts it live on that role's card", :aggregate_failures do
      expect(coder[:live]).to eq(1)
      expect(coder[:working].map { |s| s[:name] }).to eq(["fix-a work"])
    end

    it "counts it finished on the card once it is done" do
      expect(coder(filled.merge(status: "done"))[:completed].map { |s| s[:name] }).to eq(["fix-a work"])
    end

    it "leaves the other roles' cards alone" do
      expect(described_class.of([filled], %w[architect], events).first[:live]).to eq(0)
    end

    it "keeps counting a run with an agent and no part as before" do
      pinned = { name: "x", status: "busy", agent: "architect" }

      expect(described_class.of([pinned], %w[architect], events).first[:live]).to eq(1)
    end
  end

  describe ".reviews" do
    let(:jobs) { instance_double(Hecks::Adapters::ClaudeJobs, closing: "Five findings.\n**Verdict: sound with changes.**") }
    let(:runs) do
      { "s1" => { run: "w1", agent: "architect", status: "finished" }, "s2" => { run: "w2", agent: "coder", status: "started" } }
    end
    let(:transcripts) { instance_double(Hecks::Adapters::ClaudeClosingMessage, of: "") }

    def long_review = "The ports are wrong.\n#{"x" * 5000}\nVerdict: rethink"

    it "keeps a long review's first line and its last line, read whole from the transcript", :aggregate_failures do
      allow(transcripts).to receive(:of).and_return(long_review)
      review = described_class.reviews(runs, jobs, transcripts).first
      expect(review).to include(verdict: "rethink", findings: start_with("The ports are wrong."))
      expect(review[:findings]).to end_with("\nVerdict: rethink")
    end

    it "lists one review per architect run, from the job's tail when the transcript holds none", :aggregate_failures do
      reviews = described_class.reviews(runs, jobs, transcripts)
      expect(reviews.map { |review| review[:work] }).to eq(["w1"])
      expect(reviews.first).to include(verdict: "changes", findings: include("Five findings"))
    end

    it "names the Work item a review's run serves, with the review's own run key", :aggregate_failures do
      keyed = { "s3" => { run: "r-7", work_item: "w3", agent: "architect", status: "finished" } }
      expect(described_class.reviews(keyed, jobs, transcripts).first).to include(work: "w3", run: "r-7")
    end

    it "passes the unknown reason through when the runs could not be read" do
      expect(described_class.reviews({ unknown: "no launcher" }, jobs, transcripts)).to eq(unknown: "no launcher")
    end
  end

  it "has no last event when the feed could not be read" do
    expect(described_class.of([], %w[architect], { unknown: "x" }).first[:last]).to be_nil
  end
end

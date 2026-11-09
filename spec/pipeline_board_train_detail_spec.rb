# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require "hecks/pipeline_board/adapters/pipeline_web"

# What /api/trains/<run> answers: the boarding's outcome and its pull request.
RSpec.describe Hecks::Adapters::PipelineBoard::TrainDetail do
  let(:outcome) { [{ "status" => "queued", "boarded" => "d" * 40, "pushed" => "", "report" => "queued", "refusal" => "" }] }
  let(:view) do
    { "number" => 7, "url" => "https://github.com/o/r/pull/7", "state" => "OPEN",
      "statusCheckRollup" => [{ "name" => "rspec", "conclusion" => "SUCCESS", "detailsUrl" => "https://x/1" }] }
  end

  def detail(rows = outcome, pull = ->(_) { view })
    described_class.new(root: "/x", outcome: ->(_) { rows }, pull_request: pull)
  end

  it "reads the PR number, URL and checks of the boarding's branch" do
    expect(detail.of("t-1")[:pr]).to include(number: 7, state: "open",
                                             checks: [{ name: "rspec", result: "SUCCESS", url: "https://x/1" }])
  end

  it "names the PR branch after the boarded commit" do
    asked = []
    detail(outcome, ->(branch) { view.tap { asked << branch } }).of("t-1")
    expect(asked).to eq(["train/main-#{"d" * 12}"])
  end

  it "keeps the boarding when the PR cannot be read" do
    pull = ->(_) { raise Hecks::Adapters::PipelineBoard::Unavailable, "gh down" }
    expect(detail(outcome, pull).of("t-1")).to include(status: "queued", pr: nil)
  end

  it "reports a refusal as the outcome" do
    refused = [{ "status" => "faulted", "boarded" => "", "refusal" => "main moved" }]
    expect(detail(refused).of("t-1")[:outcome]).to eq("faulted: main moved")
  end

  it "answers nil when no boarding has the key" do
    expect(detail([]).of("none")).to be_nil
  end

  describe "reading the boarding from the live store" do
    let(:store) { instance_double(Hecks::Adapters::PipelineBoard::LiveStore, records: nil) }
    let(:record) { { run: "t-1", status: "faulted", refusal: "main moved", boarded: "" } }

    def detail_from_store
      allow(store).to receive(:records).with("Hecks", "SendTrain").and_return([record, { run: "t-2" }])
      described_class.new(root: "/x", live_store: store, pull_request: ->(_) { view })
    end

    it "finds the boarding by its run and starts no process", :aggregate_failures do
      probe = Hecks::Adapters::PipelineBoard::Probe
      allow(probe).to receive(:run)
      expect(detail_from_store.of("t-1")).to include(status: "faulted", outcome: "faulted: main moved")
      expect(probe).not_to have_received(:run)
    end
  end
end

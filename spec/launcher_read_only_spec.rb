# frozen_string_literal: true

require "spec_helper"
require "hecks/adapters/driving/read_only_question"

# The launcher boots without writes only for a question the bluebook's `launcher` setting lists
# under `reads_tap`, named the way the command line spells it.
RSpec.describe Hecks::Adapters::Driving::ReadOnlyQuestion do
  let(:launcher) { { reads_tap: %w[Operation.Feed] } }

  it "answers true for the listed question, however the command line spells it" do
    expect(described_class.read_only?(launcher, ["operation.feed", "limit=5"])).to be(true)
  end

  it "answers false for a question the setting does not list" do
    expect(described_class.read_only?(launcher, ["operation.follow"])).to be(false)
  end

  it "answers false when the bluebook declares no launcher setting" do
    expect(described_class.read_only?(nil, ["operation.feed"])).to be(false)
  end

  # A line may begin with the domain's word, and spell a question with underscores or camel case.
  describe "a line that begins with a domain word" do
    let(:launcher) { { reads_tap: %w[PipelineBoard.Snapshot] } }

    it "answers true for the question after the domain word" do
      words = %w[pipeline_board PipelineBoard.snapshot width.value=120]
      expect(described_class.read_only?(launcher, words)).to be(true)
    end

    it "answers true for the question spelled with an underscore" do
      expect(described_class.read_only?(launcher, ["pipeline_board.snapshot"])).to be(true)
    end

    it "answers false for another question of the same domain" do
      expect(described_class.read_only?(launcher, %w[pipeline_board PipelineBoard.serve!])).to be(false)
    end
  end

  # The pipeline polls these thousands of times a day; listed, each boots without redriving the
  # outbox and without opening the stores of aggregates it does not ask about.
  describe "the Hecks world's listing" do
    let(:described) { Hecks.describe(File.expand_path("../lib/hecks/hecks", __dir__)) }
    let(:polled) do
      [%w[tickets Work.undone], %w[agent_run.running], %w[agent_run.tidyable], %w[agents PlanReview.reviews],
       %w[agents Role.guard role.value=coder], %w[agents Role.server_env role.value=orchestrator]]
    end

    it "lists the questions the pipeline polls", :aggregate_failures do
      polled.each do |line|
        expect(described_class.for_line?(described, line, "Hecks")).to be(true), line.join(" ")
      end
    end

    it "does not list a command" do
      expect(described_class.for_line?(described, %w[tickets Work.start! to=x], "Hecks")).to be(false)
    end
  end

  describe ".for_line?" do
    it "reads the listing from the described domain's launcher setting" do
      described = instance_double(Hecks::Runtime::Loader::Described)
      allow(Hecks::Adapters::Driving::LauncherOptions).to receive(:settings).with(described, "Hecks")
                                                                            .and_return(reads_tap: %w[PipelineBoard.Snapshot])
      expect(described_class.for_line?(described, ["PipelineBoard.snapshot"], "Hecks")).to be(true)
    end
  end
end

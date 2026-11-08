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

  describe ".for_line?" do
    it "reads the listing from the described domain's launcher setting" do
      described = instance_double(Hecks::Runtime::Loader::Described)
      allow(Hecks::Adapters::Driving::LauncherOptions).to receive(:settings).with(described, "Hecks")
                                                                            .and_return(reads_tap: %w[PipelineBoard.Snapshot])
      expect(described_class.for_line?(described, ["PipelineBoard.snapshot"], "Hecks")).to be(true)
    end
  end
end

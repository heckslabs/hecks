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
end

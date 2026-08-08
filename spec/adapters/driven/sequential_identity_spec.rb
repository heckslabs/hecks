require "hecksagain"

RSpec.describe Hecksagain::Adapters::SequentialIdentity do
  before { described_class.reset! }

  it "counts up from 1, deterministically" do
    expect(described_class.uuid).to eq("1")
    expect(described_class.uuid).to eq("2")
    expect(described_class.uuid).to eq("3")
  end

  it "starts over after reset!" do
    described_class.uuid
    described_class.uuid
    described_class.reset!

    expect(described_class.uuid).to eq("1")
  end
end

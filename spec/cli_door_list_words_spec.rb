require "spec_helper"

# The launcher door folds a list argument's word spellings into an Array before the runtime
# sees them: comma-separated, repeated, and left alone for a scalar argument.
RSpec.describe Hecks::Doors::CliDoor, ".arguments" do
  let(:spec) do
    { arguments: [{ path: "labels", type: "String", required: true, list: true, words: true },
                  { path: "counts", type: "Integer", required: false, list: true, words: true },
                  { path: "name", type: "String", required: true }] }
  end

  def args(*words) = described_class.arguments(spec, words)

  it "reads a comma-separated value as a list" do
    expect(args("labels=a,b")[:labels]).to eq(%w[a b])
  end

  it "reads a repeated name as a list" do
    expect(args("labels=a", "labels=b")[:labels]).to eq(%w[a b])
  end

  it "keeps a lone word a one-item list" do
    expect(args("labels=a")[:labels]).to eq(%w[a])
  end

  it "casts each word to the element type" do
    expect(args("counts=1,2", "counts=3")[:counts]).to eq([1, 2, 3])
  end

  it "leaves a scalar argument scalar" do
    expect(args("name=a,b")[:name]).to eq("a,b")
  end
end

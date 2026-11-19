require "spec_helper"
require "hecks/hecks/adapters/landing/declarations"

# A bluebook cut into its top-level declarations gives back its text byte for byte.
RSpec.describe Hecks::Adapters::Landing::Declarations do
  let(:source) { File.read(File.expand_path("../lib/hecks/hecks/stall_watch/stall_watch.bluebook", __dir__)) }
  let(:cut) { described_class.new(source) }

  it "gives back a real bluebook byte for byte" do
    expect(cut.to_s).to eq(source)
  end

  it "keys each declaration by its kind and name" do
    expect(cut.parts.map(&:key)).to include("aggregate StallWatch", "aggregate Stall", "policy DetectOnHeartbeat")
  end

  it "keeps a declaration's leading comment with it" do
    expect(cut.by_key["aggregate StallWatch"].text).to start_with("\n    # One look at the event tap")
  end

  it "holds text with no declaration as its head" do
    expect(described_class.new("just text\n").head).to eq("just text\n")
  end
end

# frozen_string_literal: true

require "spec_helper"
require "support/train_copy_with_locals"
require "hecks/signalbox/adapters/looking"

# The beat's view counts a copy that lacks a local file, or holds another content, as missing it.
RSpec.describe Hecks::Adapters::Looking::View do
  include_context "with a train copy"

  it "counts a local file the copy lacks" do
    expect(described_class.new(copy).facts[:missing]).to eq(1)
  end

  it "counts a local file the copy holds with other content" do
    File.write(File.join(copy, "agents.local.world"), "stale")
    expect(described_class.new(copy).facts[:missing]).to eq(1)
  end
end

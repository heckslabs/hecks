require "spec_helper"
require_relative "support/lib_loading_slice"

# The lib-loading slices start a fresh process per file. On a developer machine three slices run
# together beside the coders' other work, so each takes two workers; CI gives a shard its own
# cores and takes eight.
RSpec.describe LibLoadingSlice do
  subject(:slice) { Object.new.extend(described_class) }

  it "runs two workers at once on a developer machine" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CI").and_return(nil)

    expect(slice.load_workers).to eq(2)
  end

  it "runs eight workers at once on CI" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CI").and_return("true")

    expect(slice.load_workers).to eq(8)
  end
end

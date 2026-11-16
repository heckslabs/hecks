require "spec_helper"
require_relative "support/lib_loading_slice_context"

# The lib-loading slice stops starting processes at the load the Tickets world's fill stops at.
RSpec.describe LibLoadingSlice, "#load_limit" do
  include_context "with a faked lib-loading slice"

  it "takes the world's dispatch_max_load" do
    allow(Hecks::RustBuild::WorldRows).to receive(:row).with(anything, "dispatch_max_load").and_return({ limit: 8.0 })

    expect(slice.load_limit).to eq(8.0)
  end

  it "stops waiting once the slice's wait budget is spent" do
    allow(slice).to receive_messages(load_wait_budget: -1, machine_load: 99.0)
    slice.broken_features(%w[a b])

    expect(slice).not_to have_received(:pause)
  end

  it "is 10.0 when the world names no limit" do
    allow(Hecks::RustBuild::WorldRows).to receive(:row).and_return({})

    expect(slice.load_limit).to eq(10.0)
  end
end

require "spec_helper"
require_relative "support/lib_loading_slice_context"

# The lib-loading slice stops starting processes at a fixed machine load, and stops waiting for the
# load to fall once its wait budget is spent.
RSpec.describe LibLoadingSlice, "#load_limit" do
  include_context "with a faked lib-loading slice"

  it "stops waiting once the slice's wait budget is spent" do
    allow(slice).to receive_messages(load_wait_budget: -1, machine_load: 99.0)
    slice.broken_features(%w[a b])

    expect(slice).not_to have_received(:pause)
  end

  it "is 10.0" do
    expect(slice.load_limit).to eq(10.0)
  end
end

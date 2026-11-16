require "spec_helper"
require_relative "support/lib_loading_slice_context"

# The lib-loading slice starts no process while the machine is loaded, waits a bounded time, and
# then starts anyway; CI never waits.
RSpec.describe LibLoadingSlice, "#wait_for_room" do
  include_context "with a faked lib-loading slice"

  it "starts at once when the load is under the limit" do
    loaded(0.0)
    slice.broken_features(%w[a b])

    expect(slice).not_to have_received(:pause)
  end

  it "waits at most its ticks while the machine stays loaded, then starts anyway", :aggregate_failures do
    loaded(slice.load_limit + 1)
    slice.broken_features(%w[a])

    expect(slice).to have_received(:pause).exactly(slice.load_wait_ticks).times
    expect(slice).to have_received(:load_in_subprocess).with("a")
  end

  it "waits only until the load falls" do
    loaded(slice.load_limit + 1, 0.0)
    slice.broken_features(%w[a])

    expect(slice).to have_received(:pause).once
  end

  it "never waits on CI" do
    allow(ENV).to receive(:[]).with("CI").and_return("true")
    loaded(99.0)
    slice.broken_features(%w[a])

    expect(slice).not_to have_received(:pause)
  end
end

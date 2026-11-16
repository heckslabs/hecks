require "spec_helper"
require_relative "support/lib_loading_slice_context"

# The lib-loading slice starts its fresh processes through a pool: with a fake spawner the most
# children alive at once never pass the slice's workers.
RSpec.describe LibLoadingSlice, "#broken_features" do
  include_context "with a faked lib-loading slice"

  let(:alive) { Struct.new(:now, :peak).new(0, 0) }
  let(:lock) { Mutex.new }

  before do
    loaded(0.0)
    allow(slice).to receive(:load_in_subprocess) { |_feature| fake_spawn }
  end

  def fake_spawn
    lock.synchronize { alive.peak = [alive.peak, alive.now += 1].max }
    Thread.pass
    lock.synchronize { alive.now -= 1 }
    ["", "", status]
  end

  it "never has more children at once than its workers" do
    slice.broken_features(Array.new(20) { |i| "feature#{i}" })

    expect(alive.peak).to be_between(1, slice.load_workers)
  end

  it "starts every feature it was given" do
    slice.broken_features(%w[a b c])

    expect(slice).to have_received(:load_in_subprocess).exactly(3).times
  end
end

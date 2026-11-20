require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/settled_read_looks"

# A queued boarding whose commit is already on origin/main settles even when the tap never
# recorded the merge: the `train-unmerged` row's `settled_read` asks git, so no stall files for
# it and a filed one is abandoned.
RSpec.describe "StallWatch train stalls settled by their boarded commit on origin" do
  include_context "with a stall watch tap"
  include SettledReadLooks

  let(:run) { "711c14e8-0000-4000-8000-00000000c3d4" }
  let(:merged) { [] }

  it "files a boarding left queued whose commit is not on origin" do
    queue

    expect(stalls).to eq(["stall-train-unmerged-#{run}"])
  end

  it "files nothing for a boarding whose commit is on origin" do
    merged << "b97ceff"
    queue

    expect(stalls).to be_empty
  end

  it "abandons a filed stall once its boarded commit is on origin" do
    queue
    file_stall
    merged << "b97ceff"

    expect(abandoned_reasons.first).to end_with("it settled: its boarded commit b97ceff is on origin/main")
  end

  it "keeps a filed stall whose boarded commit is not on origin" do
    queue
    file_stall

    expect(abandoned_reasons).to be_empty
  end
end

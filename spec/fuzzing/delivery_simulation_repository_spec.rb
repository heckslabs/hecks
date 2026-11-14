require "spec_helper"
require "hecks/fuzzing/delivery_simulation"

# The simulated repository alone: no runtime is booted here.
RSpec.describe Hecks::Fuzzing::DeliverySimulation::Repository, :aggregate_failures do
  subject(:git) { described_class.new("t") }

  it "fast-forwards a branch that is built on main, from one root the remote shares" do
    tip = git.branch("work/a")

    expect([git.tip("origin/main"), git.land("work/a")]).to eq(["t-c1", tip])
  end

  it "merges a branch cut before main moved, keeping both sides" do
    sides = [git.branch("work/a"), git.branch("work/b")]
    git.land("work/a")
    merged = git.land("work/b")

    expect(sides).to all(satisfy { |commit| git.ancestor?(commit, merged) })
    expect(sides).not_to include(merged)
  end

  it "refuses to move a ref that no longer names what the caller read" do
    before = git.tip("main")
    git.branch("work/a")
    git.land("work/a")

    expect { git.move_ref("main", before, expect: before) }.to raise_error(described_class::Moved, /nothing moved/)
  end

  it "loses a commit when a ref is written without a look" do
    lost = git.branch("work/a")
    git.land("work/a")
    git.write_ref("main", git.branch("work/b", from: "origin/main"))

    expect([git.known?(lost), git.ancestor?(lost, git.tip("main"))]).to eq([true, false])
  end
end

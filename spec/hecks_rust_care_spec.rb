require "spec_helper"
require_relative "support/rust_care_scratch"

# A beat of the clock asks whether the Rust build dirs are due a prune: under the Hecks world's
# free-disk line the whole prune runs, with only a gone worktree's build dir just those go, and with
# room enough, nothing gone or a Rust build running it only says why it waits.
RSpec.describe "the Rust build dirs are pruned on a beat" do
  include RustCareScratch

  let(:modes) { [] }
  let(:pruner) { ->(mode) { (modes << mode) && (3 * 1_048_576) } }

  it "prunes the whole cache when free disk is under the world's line", :aggregate_failures do
    expect(beat(free_gb: 10)).to include("RustCareDue", "RustCareHeard", "RustPruned", "RustCareSettled")
    expect(modes).to eq(%w[pressure])
  end

  it "prunes only the gone worktrees' dirs when disk is roomy", :aggregate_failures do
    expect(beat(gone: true)).to include("RustPruned", "RustCareSettled")
    expect(modes).to eq(%w[gone])
  end

  it "only says why it waits with room enough and nothing gone", :aggregate_failures do
    expect(beat).to include("RustCareDeferred", "RustCareDeclined")
    expect(modes).to be_empty
  end

  it "defers while a Rust build holds the build lock", :aggregate_failures do
    expect(beat(free_gb: 10, locked: true)).to include("RustCareDeferred")
    expect(modes).to be_empty
  end

  it "records a failed delete by name" do
    failing = ->(_mode) { raise Errno::EACCES, "target" }
    allow(self).to receive(:pruner).and_return(failing)

    expect(beat(free_gb: 10)).to include("RustPruneRefused", "RustCareRefused")
  end
end

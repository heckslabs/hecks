# frozen_string_literal: true

require "spec_helper"
require "support/stagger_steps"

# A start of a kind (a quick gate, a launcher boot) is admitted only once its spacing has passed
# since the last start of that kind, so bursts flatten into a line.
RSpec.describe "Staggering the starts of quick gates and boots" do
  include StaggerSteps

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:noon) { 1_700_000_000 }

  it "admits the first gate start of a store" do
    open_kind("gate-a")
    expect(admit("gate-a", at: noon)).to include("StartAdmitted")
  end

  it "holds a gate that starts inside the spacing, by name" do
    open_kind("gate-b")
    admit("gate-b", at: noon)
    expect(admit("gate-b", at: noon + 29)).to include(StaggerSteps::REFUSAL)
  end

  it "admits a gate once the spacing has passed" do
    open_kind("gate-c")
    admit("gate-c", at: noon)
    expect(admit("gate-c", at: noon + 30)).to include("StartAdmitted")
  end

  it "keeps a kind's spacing apart from another kind's" do
    open_kind("gate-d")
    open_kind("boot-d")
    admit("gate-d", at: noon)
    expect(admit("boot-d", at: noon + 1)).to include("StartAdmitted")
  end

  it "refuses a spacing of zero" do
    open_kind("gate-e")
    expect(admit("gate-e", at: noon, spacing: 0)).not_to include("StartAdmitted")
  end
end

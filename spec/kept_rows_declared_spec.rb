require "spec_helper"
require "hecks/hecks/adapters/local_overlaying/local_overlay"

# The overlay `LocalOverlay.write!` writes binds exactly the KeptAggregate rows, so a row naming an
# aggregate its bluebook does not declare would write a stale bind into every checkout. Retiring
# an aggregate therefore retires its row in the same change, or this spec is red.
RSpec.describe "the kept rows name declared aggregates" do
  before(:all) { @registry = boot_hecks_in_memory.registry }

  def undeclared(copy)
    rows = Hecks::Adapters::KeptRows.from_registry(@registry)
    Hecks::Adapters::KeptRows.for_copy(rows, copy).reject do |row|
      @registry.bluebook(row[:domain])&.aggregate(row[:aggregate])
    end
  end

  it "names, for the main checkout, only aggregates its domain declares" do
    expect(undeclared("main")).to eq([])
  end

  it "names, for the train's copy, only aggregates its domain declares" do
    expect(undeclared("train")).to eq([])
  end
end

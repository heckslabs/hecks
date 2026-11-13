require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The landings a settle reads for a work item: the commit of each landed `Landing` whose branch is
# the work item's key, or the key with QA's prefix, as the LandedWork port names a branch's item.
RSpec.describe Hecks::Adapters::Dispatching::WorkItems, "#landed_commits" do
  let(:registry) { boot_hecks_in_memory.registry }
  let(:landings) do
    [{ branch: "a", landed: "1111", status: "landed" }, { branch: "qa/a", landed: "2222", status: "landed" },
     { branch: "a", landed: "", status: "refused" }, { branch: "ab", landed: "3333", status: "landed" }]
  end

  def work_items
    held = Struct.new(:all).new(landings)
    allow(registry).to receive(:repository).and_wrap_original do |original, domain, aggregate|
      aggregate.hecks_name == "Landing" ? held : original.call(domain, aggregate)
    end
    described_class.new(registry)
  end

  it "answers the commits of the work item's landed branches, QA's included" do
    expect(work_items.landed_commits("a")).to eq(%w[1111 2222])
  end

  it "answers nothing for a work item no branch landed for" do
    expect(work_items.landed_commits("b")).to eq([])
  end

  it "answers when the work item started, empty for one the store does not hold" do
    expect(work_items.claimed_at("b")).to eq("")
  end
end

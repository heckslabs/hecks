require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The landings a settle reads when a branch carries `LinkedTree.add!`'s collision suffix: a landing
# of `a-2` is a landing of `a`, unless `a-2` is a work item of its own.
RSpec.describe Hecks::Adapters::Dispatching::WorkItems, "#landed_commits with a suffix" do
  let(:registry) { boot_hecks_in_memory.registry }
  let(:landings) { [{ branch: "a", landed: "1111", status: "landed" }, { branch: "a-2", landed: "2222", status: "landed" }] }

  def repositories(keys)
    { "Landing" => Struct.new(:all).new(landings), "Work" => Struct.new(:all).new(keys.map { |key| { work: key } }) }
  end

  def landed_for(key, keys)
    held = repositories(keys)
    allow(registry).to receive(:repository).and_wrap_original do |original, domain, aggregate|
      held.fetch(aggregate.hecks_name) { original.call(domain, aggregate) }
    end
    described_class.new(registry).landed_commits(key)
  end

  it "counts the suffixed branch as the item's landing" do
    expect(landed_for("a", %w[a])).to eq(%w[1111 2222])
  end

  it "does not count it when the suffixed name is a work item" do
    expect(landed_for("a", %w[a a-2])).to eq(%w[1111])
  end

  it "counts it for the suffixed item itself" do
    expect(landed_for("a-2", %w[a a-2])).to eq(%w[2222])
  end
end

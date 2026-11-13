require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# Which landing counts: one of the work item's branch whose commit was made at or after the work
# item started, so an earlier landing of a reopened work item does not finish its new start.
RSpec.describe Hecks::Adapters::Dispatching::LandedSince do
  let(:landings) { { "a" => %w[old new], "unread" => %w[gone] } }
  let(:times) { { "old" => "2026-11-12T00:00:00Z", "new" => "2026-11-12T02:04:00+00:00" } }

  def work_items(claimed)
    instance_double(Hecks::Adapters::Dispatching::WorkItems, claimed_at: claimed).tap do |items|
      allow(items).to receive(:landed_commits) { |key| landings.fetch(key, []) }
    end
  end

  def landed(key, claimed = "2026-11-12T01:53:57Z")
    described_class.new(work_items(claimed), committed_at: ->(sha) { times[sha] }).call(key)
  end

  it "answers the commit made after the start" do
    expect(landed("a")).to eq("new")
  end

  it "answers nothing for a landing made before the start" do
    expect(landed("a", "2026-11-12T03:00:00Z")).to be_nil
  end

  it "answers nothing when the work item records no start" do
    expect(landed("a", "")).to be_nil
  end

  it "answers nothing for a commit whose time cannot be read" do
    expect(landed("unread")).to be_nil
  end

  it "answers nothing for a work item with no landing" do
    expect(landed("none")).to be_nil
  end
end

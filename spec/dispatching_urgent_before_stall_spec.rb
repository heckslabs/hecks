require "spec_helper"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Filed stall items never take the places urgent work needs: a priority-now item ranks ahead of
# every stall, and the stalls, started and chosen together, hold one place in all.
RSpec.describe "a fill with stall items and urgent work" do
  include_context "with a stall watch tap"

  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def fill(started:, cap: 4)
    items = Hecks::Adapters::Dispatching::WorkItems.new(registry)
    Hecks::Adapters::Dispatching::Plan.new(items.planned, started.map { |key| item(key) },
                                           cap: cap, load: 1.0, max_load: 20.0, frozen: [], urgent_reserve: 1,
                                           stall: Hecks::Adapters::Dispatching::SettleRule.stall(items))
  end

  before do
    %w[stall-plan-review-a stall-plan-review-b stall-plan-review-c].each { |work| plan(work) }
    plan("urgent-fix", "now")
  end

  it "starts the priority-now item in the one free place, ahead of three stalls" do
    expect(fill(started: %w[s1 s2 s3]).chosen.map(&:key)).to eq(["urgent-fix"])
  end

  it "gives the stalls one place in all when more are free" do
    expect(fill(started: [], cap: 4).chosen.map(&:key)).to eq(%w[urgent-fix stall-plan-review-a])
  end

  it "holds every stall while a started stall has the one stall place" do
    expect(fill(started: %w[stall-plan-review-z], cap: 4).skipped.map(&:reason).uniq)
      .to eq(["skipped: held: stall stall-plan-review-z already holds the one stall place"])
  end
end

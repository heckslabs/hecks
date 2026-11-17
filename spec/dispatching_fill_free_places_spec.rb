require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill starts at most the places the cap has free, a red work item included; the red reserve is
# spent only when no place is free.
RSpec.describe "the places a fill may start" do
  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def chosen(planned:, started:, cap: 4)
    plan = Hecks::Adapters::Dispatching::Plan.new(planned.map { |key| item(key) }, started.map { |key| item(key) },
                                                  cap: cap, load: 1.0, max_load: 20.0, frozen: [], urgent_reserve: 1,
                                                  exempt: Hecks::Adapters::Dispatching::WorkItems.method(:red?))
    plan.chosen.map(&:key)
  end

  it "starts one item when one place is free, a red one among the planned included" do
    expect(chosen(planned: %w[red-a b], started: %w[s1 s2 s3])).to eq(["red-a"])
  end

  it "starts what the free places hold and no more" do
    expect(chosen(planned: %w[a b c], started: %w[s1 s2])).to eq(%w[a b])
  end

  it "still starts a red item through the reserve when the cap is full" do
    expect(chosen(planned: %w[red-a], started: %w[s1 s2 s3 s4])).to eq(["red-a"])
  end

  it "starts a second red item through the reserve only once" do
    expect(chosen(planned: %w[red-a red-b], started: %w[s1 s2 s3 s4])).to eq(["red-a"])
  end
end

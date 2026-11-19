require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A fill starts at most the places the cap has free, a red work item included; the red reserve is
# spent only when no place is free. With free places and startable work items it fills every place,
# whatever the headroom estimate says, and names the reason of each work item it leaves waiting.
RSpec.describe "the places a fill may start" do
  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def plan(planned:, started:, cap: 4, **limits)
    Hecks::Adapters::Dispatching::Plan.new(planned.map { |key| item(key) }, started.map { |key| item(key) },
                                           cap: cap, load: 1.0, max_load: 20.0, frozen: [], urgent_reserve: 1,
                                           exempt: Hecks::Adapters::Dispatching::WorkItems.method(:red?), **limits)
  end

  def chosen(...) = plan(...).chosen.map(&:key)

  # Cap 6, one started, the estimate saying room for one, six startable items and two that wait.
  def ledger
    clash = Hecks::Adapters::Dispatching::Plan::Item.new(key: "clash", title: "clash", detail: "", area: ["s1"])
    planned = %w[a b c d e f].map { |key| item(key) } + [clash, item("after-z")]
    Hecks::Adapters::Dispatching::Plan.new(planned, [item("s1")], cap: 6, load: 18.0, max_load: 20.5, frozen: [],
                                                                  headroom: 1, per_session: 1.6, waits: method(:waits))
  end

  def waits(entry) = entry.key == "after-z" ? "skipped: waits on z" : nil

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

  it "fills every free place when as many startable items wait, whatever the headroom estimate says" do
    expect(ledger.chosen.map(&:key)).to eq(%w[a b c d e])
  end

  it "reports each skipped item with its reason" do
    expect(ledger.skipped.to_h { |skip| [skip.key, skip.reason] })
      .to eq("f" => "skipped: cap 6 reached (1 started, 5 chosen by this fill)",
             "clash" => "skipped: cap 6 reached (1 started, 5 chosen by this fill)", "after-z" => "skipped: waits on z")
  end
end

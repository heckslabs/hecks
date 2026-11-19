require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The settle says what it did with every started work item: one that landed is settled, one
# whose session failed is yielded with the condition, and one still working or blocked on a
# person is left, with why. A runner stand-in answers the launcher's commands.
RSpec.describe Hecks::Adapters::Dispatching::Settler, "#call" do
  let(:dispatching) { Hecks::Adapters::Dispatching }
  let(:launcher) { dispatching::Launcher.new("/scratch", runner: ->(_argv) { Hecks::Adapters::Shell::Result.new("{}", "", ok) }) }
  let(:items) do
    instance_double(dispatching::WorkItems, started: %w[d f w].map { |key| item(key) }, runs: runs, landing_in_flight?: false)
  end
  let(:runs) { { "d" => run("finished", "done"), "f" => run("finished", "failed"), "w" => run("started", "working") } }
  let(:ok) { instance_double(Process::Status, success?: true, exitstatus: 0) }

  def item(key) = dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [])

  def run(status, condition) = { status: status, condition: condition, started_at: "2026-11-19T10:00:00Z" }

  def settle = described_class.new(items, launcher, landed: ->(key) { "bd4ff9f93aa" if key == "d" }).call

  it "settles the landed item, yields the failed one and says the working one was left" do
    expect(settle).to eq(["finished d: landed as bd4ff9f93, finishing instead", "yielded f: its session ended failed",
                          "left w: its session is still working (started 2026-11-19T10:00:00Z)"])
  end

  context "when a session is blocked on a person" do
    let(:runs) { { "w" => run("started", "blocked") } }

    it "says it was left blocked, naming when its run started" do
      expect(settle.last).to eq("left w: its session is blocked on a person (its run started 2026-11-19T10:00:00Z)")
    end
  end

  context "when a work item has no run" do
    let(:runs) { {} }

    it("says so for each") { expect(settle).to eq(%w[d f w].map { |key| "left #{key}: no run is recorded for it" }) }
  end
end
